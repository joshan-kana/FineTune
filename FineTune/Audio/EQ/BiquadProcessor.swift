// FineTune/Audio/EQ/BiquadProcessor.swift
import Foundation
import Accelerate
import Darwin.C  // OSMemoryBarrier
import os

// vDSP_biquad_Setup is a C typedef of OpaquePointer; the Sendable conformance
// doesn't survive the typealias, so this wrapper carries the safety claim that
// the rt-safety.md "deferred destruction" pattern already documents: the 500ms
// delay before vDSP_biquad_DestroySetup exceeds worst-case audio buffer
// duration (4096 frames @ 44.1kHz ≈ 93ms), so the audio thread has moved past
// the old setup by the time the closure fires.
private struct BiquadSetupBox: @unchecked Sendable {
    let setup: vDSP_biquad_Setup
}

/// Base class for RT-safe biquad filter processors.
///
/// Manages delay buffers, atomic setup swaps, and the core stereo biquad processing loop.
/// Subclasses provide coefficient computation via `recomputeCoefficients()` and optional
/// pre-processing via `preProcess()`.
///
/// ## RT-Safety
/// `process()` runs on CoreAudio's HAL I/O thread. All state it accesses uses
/// `nonisolated(unsafe)` for lock-free atomic reads. Setup updates use atomic pointer
/// swaps with deferred destruction (500ms grace period).
///
/// ## Subclasses
/// - `EQProcessor`: Per-app 10-band graphic EQ
/// - `AutoEQProcessor`: Per-device headphone correction
class BiquadProcessor: @unchecked Sendable, BiquadProcessable {

    let logger: Logger

    /// Current sample rate in Hz. Main thread only.
    private(set) var sampleRate: Double

    // MARK: - RT-Safe State

    /// Biquad filter setup pointer. Swapped atomically; old setup deferred-destroyed.
    private nonisolated(unsafe) var _eqSetup: vDSP_biquad_Setup?

    /// Processing enable flag. Audio callback reads this atomically at entry.
    /// Subclasses set via `setEnabled(_:)` from their update methods (main thread only).
    private nonisolated(unsafe) var _isEnabled: Bool

    // MARK: - Pre-allocated Delay Buffers

    private let delayBuffer: UnsafeMutablePointer<Float>
    private let delayBufferSize: Int
    private let channelCapacity = 8

    /// Whether biquad processing is active (RT-safe read).
    var isEnabled: Bool { _isEnabled }

    /// Set the processing enable flag. Main thread only.
    func setEnabled(_ enabled: Bool) {
        _isEnabled = enabled
    }

    // MARK: - Init / Deinit

    /// - Parameters:
    ///   - sampleRate: Initial device sample rate in Hz.
    ///   - maxSections: Maximum number of biquad sections. Determines delay buffer size: `(2 * maxSections) + 2`.
    ///   - category: Logger category for this processor instance.
    ///   - initiallyEnabled: Whether processing starts enabled. Default `false`.
    init(sampleRate: Double, maxSections: Int, category: String, initiallyEnabled: Bool = false) {
        self.sampleRate = sampleRate
        self.logger = Logger(subsystem: "com.finetuneapp.FineTune", category: category)
        self._isEnabled = initiallyEnabled
        self.delayBufferSize = (2 * maxSections) + 2

        delayBuffer = .allocate(capacity: delayBufferSize * channelCapacity)
        delayBuffer.initialize(repeating: 0, count: delayBufferSize * channelCapacity)
    }

    deinit {
        if let setup = _eqSetup {
            vDSP_biquad_DestroySetup(setup)
        }
        delayBuffer.deallocate()
    }

    // MARK: - Setup Management (main thread)

    /// Atomically swap the biquad setup, deferring destruction of the old one.
    ///
    /// The 500ms delay ensures the audio thread has moved on from the old setup.
    /// Worst-case audio buffer is 4096 frames @ 44.1kHz = 93ms, plus scheduling jitter.
    func swapSetup(_ newSetup: vDSP_biquad_Setup?) {
        let oldSetup = _eqSetup
        _eqSetup = newSetup
        if let old = oldSetup {
            let box = BiquadSetupBox(setup: old)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                vDSP_biquad_DestroySetup(box.setup)
            }
        }
    }

    /// Reset delay buffers with barrier protection.
    ///
    /// Temporarily disables processing to prevent the audio thread from reading
    /// partially-zeroed state. Call from main thread after a sample rate change.
    func resetDelayBuffers() {
        let wasEnabled = _isEnabled
        _isEnabled = false
        OSMemoryBarrier()

        memset(delayBuffer, 0, delayBufferSize * channelCapacity * MemoryLayout<Float>.size)

        _isEnabled = wasEnabled
        OSMemoryBarrier()
    }

    /// Update sample rate and recompute coefficients.
    ///
    /// Calls `recomputeCoefficients()` to get new coefficients from the subclass,
    /// then atomically swaps the setup and resets delay buffers.
    func updateSampleRate(_ newRate: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        let oldRate = sampleRate
        guard newRate != sampleRate else { return }
        sampleRate = newRate

        guard let (coefficients, sectionCount) = recomputeCoefficients() else {
            // No state loaded — rate saved for future use
            return
        }

        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(sectionCount))
        }

        guard let newSetup else {
            logger.warning("vDSP_biquad_CreateSetup returned nil at \(newRate, format: .fixed(precision: 0))Hz")
            return
        }

        // We inline the swap + reset here instead of calling swapSetup() + resetDelayBuffers()
        // because the ordering is critical: disable → swap → reset → re-enable must be atomic.
        // Calling them separately would leave a window where the audio thread could process
        // new coefficients with stale delay buffer state.
        let oldSetup = _eqSetup
        let wasEnabled = _isEnabled
        _isEnabled = false
        OSMemoryBarrier()

        _eqSetup = newSetup
        memset(delayBuffer, 0, delayBufferSize * channelCapacity * MemoryLayout<Float>.size)

        _isEnabled = wasEnabled
        OSMemoryBarrier()

        if let old = oldSetup {
            let box = BiquadSetupBox(setup: old)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                vDSP_biquad_DestroySetup(box.setup)
            }
        }

        logger.info("Sample rate: \(oldRate, format: .fixed(precision: 0))Hz → \(newRate, format: .fixed(precision: 0))Hz")
    }

    // MARK: - Subclass Hooks

    /// Override to provide coefficients for the current state at the current sample rate.
    /// Called during `updateSampleRate()`. Return `nil` if no state is loaded.
    ///
    /// - Returns: Tuple of (flat coefficient array in vDSP format, number of biquad sections),
    ///   or `nil` to skip recomputation.
    func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        return nil
    }

    /// Override to apply pre-processing before the biquad cascade (e.g. preamp gain).
    /// Called after input is copied to output, before biquad processing. **Must be RT-safe.**
    ///
    /// Default implementation is a no-op.
    func preProcess(output: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        // No-op — subclasses override
    }

    // MARK: - Audio Processing (RT-safe)

    /// Process stereo interleaved audio. RT-safe: no allocations, locks, ObjC, or I/O.
    /// Can process in-place (input == output).
    ///
    /// - Parameters:
    ///   - input: Input buffer (stereo interleaved Float32).
    ///   - output: Output buffer (stereo interleaved Float32).
    ///   - frameCount: Number of stereo frames (total samples / 2).
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        process(input: input, output: output, frameCount: frameCount, channelCount: 2, channelOffset: 0)
    }

    /// Processes an interleaved buffer with any channel count up to the
    /// supported capacity. Each channel has independent filter state.
    func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        channelOffset: Int = 0
    ) {
        let safeChannels = min(max(1, channelCount), channelCapacity - max(0, channelOffset))
        guard frameCount > 0, safeChannels > 0 else { return }
        let enabled = _isEnabled
        let setup = _eqSetup

        // Bypass: copy input to output
        guard enabled, let setup = setup else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * safeChannels * MemoryLayout<Float>.size)
            }
            return
        }

        // Copy input to output for in-place processing
        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * safeChannels * MemoryLayout<Float>.size)
        }

        // Subclass hook for pre-processing (e.g. preamp gain)
        preProcess(output: output, frameCount: frameCount, channelCount: safeChannels)

        for channel in 0..<safeChannels {
            let state = delayBuffer.advanced(by: (channelOffset + channel) * delayBufferSize)
            let samples = output.advanced(by: channel)
            vDSP_biquad(setup, state, samples, vDSP_Stride(safeChannels), samples, vDSP_Stride(safeChannels), vDSP_Length(frameCount))
        }

        // NaN safety net — pathological coefficients can produce NaN that
        // propagates through the entire downstream chain
        var invalid = false
        for channel in 0..<safeChannels where output[channel].isNaN || output[channel].isInfinite {
            invalid = true
        }
        if invalid {
            memset(delayBuffer, 0, delayBufferSize * channelCapacity * MemoryLayout<Float>.size)
            memset(output, 0, frameCount * safeChannels * MemoryLayout<Float>.size)
        }
    }
}
