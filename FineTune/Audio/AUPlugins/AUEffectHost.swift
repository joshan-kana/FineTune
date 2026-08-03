import AudioToolbox
import Foundation
import os

/// Real-time-safe host for one Audio Unit instance.
///
/// Audio Units are prepared, negotiated, and initialized before the render
/// callback starts. The callback only copies between preallocated channel
/// buffers and calls `AudioUnitRender`; it performs no allocation, locking,
/// logging, Objective-C messaging, or I/O.
final class AUEffectHost: @unchecked Sendable {
    let descriptor: AUPluginDescriptor
    let entryID: UUID
    let format: AudioStreamFormatDescription
    let processingMode: AUProcessingMode

    private nonisolated(unsafe) var _audioUnit: AudioUnit?
    private nonisolated(unsafe) var _isEnabled: Bool
    private nonisolated(unsafe) var _sampleTime: Float64 = 0

    let _bufferCapacity: Int
    let _channelCapacity: Int
    let _inputChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    let _outputChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let _renderABL: UnsafeMutablePointer<AudioBufferList>
    private let _singleBufferABL: UnsafeMutablePointer<AudioBufferList>

    private(set) var factoryPresets: [(index: Int, name: String)] = []
    private(set) var tailTimeSeconds: Double = 0
    private(set) var latencySeconds: Double = 0
    private(set) var supportedChannelCounts: [(input: Int, output: Int)] = []
    private(set) var supportedLayoutTags: [AudioChannelLayoutTag] = []
    private(set) var canProcessCurrentLayout = false

    private let logger: Logger
    private let maxFrames: UInt32

    var isEnabled: Bool { _isEnabled }
    var audioUnit: AudioUnit? { _audioUnit }

    var compatibilityDescription: String {
        guard canProcessCurrentLayout else {
            if processingMode == .stereoOnly && format.channelCount != 2 {
                return "Stereo only — bypassed on (format.shortLabel)"
            }
            return "Unsupported (format.shortLabel) layout — audio preserved"
        }
        switch processingMode {
        case .nativeMultichannel: return "Native (format.shortLabel)"
        case .independentPerChannel: return "Independent ×(format.channelCount)"
        case .stereoOnly: return "Stereo only"
        case .bypassForLayout: return "Bypass for this layout"
        case .auto: return format.channelCount > 2 ? "Native (format.shortLabel)" : "Native stereo"
        }
    }

    init(
        descriptor: AUPluginDescriptor,
        entryID: UUID,
        sampleRate: Double,
        maxFrames: UInt32 = 4096,
        enabled: Bool = true,
        format: AudioStreamFormatDescription? = nil,
        processingMode: AUProcessingMode = .auto
    ) {
        self.descriptor = descriptor
        self.entryID = entryID
        self.maxFrames = max(1, maxFrames)
        self.format = format ?? AudioStreamFormatDescription(sampleRate: sampleRate, frameCapacity: maxFrames, channelCount: 2, isInterleaved: false)
        self.processingMode = processingMode
        self._isEnabled = enabled
        self._bufferCapacity = Int(maxFrames)
        self._channelCapacity = max(1, self.format.channelCount)
        self._inputChannels = .allocate(capacity: _channelCapacity)
        self._outputChannels = .allocate(capacity: _channelCapacity)
        self._inputChannels.initialize(repeating: nil, count: _channelCapacity)
        self._outputChannels.initialize(repeating: nil, count: _channelCapacity)

        for index in 0..<_channelCapacity {
            let input = UnsafeMutablePointer<Float>.allocate(capacity: Int(maxFrames))
            input.initialize(repeating: 0, count: Int(maxFrames))
            _inputChannels[index] = input
            let output = UnsafeMutablePointer<Float>.allocate(capacity: Int(maxFrames))
            output.initialize(repeating: 0, count: Int(maxFrames))
            _outputChannels[index] = output
        }

        let listSize = MemoryLayout<AudioBufferList>.size + max(0, _channelCapacity - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: listSize)
        self._renderABL = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        let singleRaw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size, alignment: MemoryLayout<AudioBufferList>.alignment)
        singleRaw.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<AudioBufferList>.size)
        self._singleBufferABL = singleRaw.bindMemory(to: AudioBufferList.self, capacity: 1)

        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AUEffectHost[\(descriptor.name)]")
    }

    deinit {
        if let au = _audioUnit {
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        for index in 0..<_channelCapacity {
            _inputChannels[index]?.deallocate()
            _outputChannels[index]?.deallocate()
        }
        _inputChannels.deallocate()
        _outputChannels.deallocate()
        _renderABL.deallocate()
        _singleBufferABL.deallocate()
    }

    // MARK: - Main-thread preparation

    func instantiate() -> Bool {
        var desc = descriptor.audioComponentDescription
        guard let component = AudioComponentFindNext(nil, &desc) else {
            logger.error("AudioComponent not found for \(self.descriptor.name)")
            return false
        }

        var au: AudioUnit?
        var err = AudioComponentInstanceNew(component, &au)
        guard err == noErr, let au else {
            logger.error("AudioComponentInstanceNew failed: \(err)")
            return false
        }

        supportedChannelCounts = querySupportedChannelCounts(au)
        supportedLayoutTags = querySupportedLayoutTags(au)
        canProcessCurrentLayout = supportsCurrentLayout
        if processingMode == .bypassForLayout {
            canProcessCurrentLayout = false
        }

        // A stereo-only mode never attempts an implicit multichannel downmix.
        if processingMode == .stereoOnly && format.channelCount != 2 {
            canProcessCurrentLayout = false
        }

        // Apple effects are hosted with non-interleaved Float32 buffers. The
        // source stream's interleaving is converted in preallocated memory.
        var streamFormat = AudioStreamFormatDescription(
            sampleRate: format.sampleRate,
            frameCapacity: format.frameCapacity,
            channelCount: format.channelCount,
            isInterleaved: false,
            channelLayoutTag: format.channelLayoutTag
        ).audioStreamBasicDescription

        err = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if err != noErr { logger.warning("Failed to set input stream format: \(err)") }
        err = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if err != noErr { logger.warning("Failed to set output stream format: \(err)") }

        if var layout = format.audioUnitLayout() {
            _ = withUnsafePointer(to: &layout) { layoutPtr in
                AudioUnitSetProperty(au, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0, layoutPtr, UInt32(MemoryLayout<AudioChannelLayout>.size))
            }
            _ = withUnsafePointer(to: &layout) { layoutPtr in
                AudioUnitSetProperty(au, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Output, 0, layoutPtr, UInt32(MemoryLayout<AudioChannelLayout>.size))
            }
        }

        var frames = maxFrames
        _ = AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))

        var callback = AURenderCallbackStruct(inputProc: auRenderCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        err = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard err == noErr else {
            logger.error("Failed to set render callback: \(err)")
            AudioComponentInstanceDispose(au)
            return false
        }

        err = AudioUnitInitialize(au)
        guard err == noErr else {
            logger.error("AudioUnitInitialize failed: \(err)")
            AudioComponentInstanceDispose(au)
            return false
        }

        _audioUnit = au
        loadFactoryPresets()
        queryTailTime()
        queryLatency()
        logger.info("Instantiated \(self.descriptor.name) at \(self.format.shortLabel), \(self.format.sampleRate)Hz, \(self.compatibilityDescription)")
        return true
    }

    func setEnabled(_ enabled: Bool) { _isEnabled = enabled }

    // MARK: - Real-time rendering

    @inline(__always)
    func renderInterleaved(samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        _singleBufferABL.pointee.mNumberBuffers = 1
        let list = UnsafeMutableAudioBufferListPointer(_singleBufferABL)
        list[0] = AudioBuffer(mNumberChannels: UInt32(format.channelCount), mDataByteSize: UInt32(max(0, frameCount) * format.channelCount * MemoryLayout<Float>.size), mData: samples)
        renderBuffers(list, frameCount: frameCount)
    }

    @inline(__always)
    func renderBuffers(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard _isEnabled, canProcessCurrentLayout, _audioUnit != nil else { return }
        let count = min(max(0, frameCount), _bufferCapacity)
        guard count > 0, buffers.count > 0 else { return }
        let view = AudioBufferListFormatView(buffers)
        guard view.channelCount == format.channelCount else { return }

        copyToPlanar(buffers, frameCount: count)

        let byteCount = UInt32(count * MemoryLayout<Float>.size)
        let renderBuffers = UnsafeMutableAudioBufferListPointer(_renderABL)
        _renderABL.pointee.mNumberBuffers = UInt32(format.channelCount)
        for channel in 0..<format.channelCount {
            renderBuffers[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: _outputChannels[channel])
        }

        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        timestamp.mSampleTime = _sampleTime
        _sampleTime += Float64(count)
        guard let au = _audioUnit, AudioUnitRender(au, &flags, &timestamp, 0, UInt32(count), _renderABL) == noErr else { return }

        copyFromPlanar(buffers, frameCount: count)
    }

    /// Processes one logical channel without pairing it with another channel.
    /// `stride` is the number of interleaved channels; use 1 for a planar buffer.
    @inline(__always)
    func renderChannel(samples: UnsafeMutablePointer<Float>, frameCount: Int, stride: Int) {
        guard _isEnabled, canProcessCurrentLayout, _audioUnit != nil else { return }
        let count = min(max(0, frameCount), _bufferCapacity)
        guard count > 0, let input = _inputChannels[0], let output = _outputChannels[0] else { return }
        let safeStride = max(1, stride)
        for frame in 0..<count { input[frame] = samples[frame * safeStride] }
        let byteCount = UInt32(count * MemoryLayout<Float>.size)
        let renderBuffers = UnsafeMutableAudioBufferListPointer(_renderABL)
        _renderABL.pointee.mNumberBuffers = 1
        renderBuffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: output)
        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        timestamp.mSampleTime = _sampleTime
        _sampleTime += Float64(count)
        guard let au = _audioUnit, AudioUnitRender(au, &flags, &timestamp, 0, UInt32(count), _renderABL) == noErr else { return }
        for frame in 0..<count { samples[frame * safeStride] = output[frame] }
    }

    // MARK: - Presets and diagnostics

    func savePreset() -> Data? {
        guard let au = _audioUnit else { return nil }
        var classInfo: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let err = AudioUnitGetProperty(au, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &classInfo, &size)
        guard err == noErr, let plist = classInfo?.takeRetainedValue() else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    func loadPreset(_ data: Data) -> Bool {
        guard let au = _audioUnit, let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        let cfPlist = plist as CFPropertyList
        var mutablePlist: CFPropertyList? = cfPlist
        let err = AudioUnitSetProperty(au, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &mutablePlist, UInt32(MemoryLayout<CFPropertyList?>.size))
        if err != noErr { logger.warning("Failed to load preset: \(err)") }
        queryTailTime()
        queryLatency()
        return err == noErr
    }

    func selectFactoryPreset(index: Int) -> Bool {
        guard let au = _audioUnit else { return false }
        var preset = AUPreset(presetNumber: Int32(index), presetName: nil)
        let err = AudioUnitSetProperty(au, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &preset, UInt32(MemoryLayout<AUPreset>.size))
        if err != noErr { logger.warning("Failed to select factory preset \(index): \(err)") }
        queryTailTime()
        queryLatency()
        return err == noErr
    }

    private var supportsCurrentLayout: Bool {
        guard !supportedChannelCounts.isEmpty else { return format.channelCount == 2 }
        return supportedChannelCounts.contains { pair in
            let inputMatches = pair.input < 0 ? true : pair.input == format.channelCount
            let outputMatches = pair.output < 0 ? true : pair.output == format.channelCount
            return inputMatches && outputMatches
        }
    }

    private func querySupportedChannelCounts(_ au: AudioUnit) -> [(input: Int, output: Int)] {
        var size: UInt32 = 0
        let infoErr = AudioUnitGetPropertyInfo(au, kAudioUnitProperty_SupportedNumChannels, kAudioUnitScope_Global, 0, &size, nil)
        guard infoErr == noErr, size >= UInt32(MemoryLayout<AUChannelInfo>.size) else { return [] }
        let count = Int(size) / MemoryLayout<AUChannelInfo>.size
        let ptr = UnsafeMutablePointer<AUChannelInfo>.allocate(capacity: count)
        defer { ptr.deallocate() }
        var mutableSize = size
        guard AudioUnitGetProperty(au, kAudioUnitProperty_SupportedNumChannels, kAudioUnitScope_Global, 0, ptr, &mutableSize) == noErr else { return [] }
        return (0..<count).map { (Int(ptr[$0].inChannels), Int(ptr[$0].outChannels)) }
    }

    private func querySupportedLayoutTags(_ au: AudioUnit) -> [AudioChannelLayoutTag] {
        var size: UInt32 = 0
        let infoErr = AudioUnitGetPropertyInfo(au, kAudioUnitProperty_SupportedChannelLayoutTags, kAudioUnitScope_Global, 0, &size, nil)
        guard infoErr == noErr, size >= UInt32(MemoryLayout<AudioChannelLayoutTag>.size) else { return [] }
        let count = Int(size) / MemoryLayout<AudioChannelLayoutTag>.size
        let ptr = UnsafeMutablePointer<AudioChannelLayoutTag>.allocate(capacity: count)
        defer { ptr.deallocate() }
        var mutableSize = size
        guard AudioUnitGetProperty(au, kAudioUnitProperty_SupportedChannelLayoutTags, kAudioUnitScope_Global, 0, ptr, &mutableSize) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    private func loadFactoryPresets() {
        guard let au = _audioUnit else { return }
        var presetsRef: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioUnitGetProperty(au, kAudioUnitProperty_FactoryPresets, kAudioUnitScope_Global, 0, &presetsRef, &size) == noErr,
              let cfArray = presetsRef?.takeRetainedValue() else { factoryPresets = []; return }
        let count = CFArrayGetCount(cfArray)
        factoryPresets = (0..<count).compactMap { index in
            guard let ptr = CFArrayGetValueAtIndex(cfArray, index) else { return nil }
            let preset = ptr.load(as: AUPreset.self)
            let name = preset.presetName?.takeUnretainedValue() as String? ?? "Preset \(preset.presetNumber)"
            return (index: Int(preset.presetNumber), name: name)
        }
    }

    private func queryTailTime() {
        guard let au = _audioUnit else { return }
        var tail: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let err = AudioUnitGetProperty(au, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0, &tail, &size)
        tailTimeSeconds = err == noErr && tail.isFinite ? max(0, tail) : 0
    }

    private func queryLatency() {
        guard let au = _audioUnit else { return }
        var latency: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let err = AudioUnitGetProperty(au, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size)
        latencySeconds = err == noErr && latency.isFinite ? max(0, latency) : 0
    }

    @inline(__always)
    private func copyToPlanar(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        var channel = 0
        for buffer in buffers {
            guard channel < _channelCapacity, let data = buffer.mData else { channel += max(1, Int(buffer.mNumberChannels)); continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = data.assumingMemoryBound(to: Float.self)
            if channels == 1 {
                memcpy(_inputChannels[channel], samples, frameCount * MemoryLayout<Float>.size)
            } else {
                for frame in 0..<frameCount {
                    for local in 0..<channels where channel + local < _channelCapacity {
                        _inputChannels[channel + local]![frame] = samples[frame * channels + local]
                    }
                }
            }
            channel += channels
        }
    }

    @inline(__always)
    private func copyFromPlanar(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        var channel = 0
        for buffer in buffers {
            guard channel < _channelCapacity, let data = buffer.mData else { channel += max(1, Int(buffer.mNumberChannels)); continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = data.assumingMemoryBound(to: Float.self)
            if channels == 1 {
                memcpy(samples, _outputChannels[channel], frameCount * MemoryLayout<Float>.size)
            } else {
                for frame in 0..<frameCount {
                    for local in 0..<channels where channel + local < _channelCapacity {
                        samples[frame * channels + local] = _outputChannels[channel + local]![frame]
                    }
                }
            }
            channel += channels
        }
    }
}

@inline(__always)
private func auRenderCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let host = Unmanaged<AUEffectHost>.fromOpaque(inRefCon).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    let frameCount = min(Int(inNumberFrames), host._bufferCapacity)
    for index in 0..<buffers.count {
        guard index < host._channelCapacity, let data = buffers[index].mData, let source = host._inputChannels[index] else { continue }
        memcpy(data, source, frameCount * MemoryLayout<Float>.size)
    }
    return noErr
}
