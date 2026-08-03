import AudioToolbox
import Foundation
import os

/// Ordered, immutable Audio Unit chain.
///
/// A chain can contain one native N-channel host per entry or N independent
/// mono hosts for a channel-independent effect. The choice is made during
/// construction, never on the render thread.
final class AUEffectChain: @unchecked Sendable {
    let entries: [AUEffectChainEntry]
    let failedEntryIDs: Set<UUID>
    let unsupportedEntryIDs: Set<UUID>
    let format: AudioStreamFormatDescription

    private let _hosts: [AUEffectHost]
    private let hostGroups: [[AUEffectHost]]
    private let hostGroupsByEntryID: [UUID: [AUEffectHost]]
    private nonisolated(unsafe) var _isBypassed = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AUEffectChain")

    var isBypassed: Bool { _isBypassed }
    var hosts: [AUEffectHost] { _hosts }
    var maxTailTime: Double { hostGroups.flatMap { $0 }.filter { $0.isEnabled }.map(\.tailTimeSeconds).max() ?? 0 }
    var aggregateLatencySeconds: Double { hostGroups.flatMap { $0 }.filter { $0.isEnabled }.reduce(0) { $0 + $1.latencySeconds } }

    init(
        entries: [AUEffectChainEntry],
        sampleRate: Double,
        maxFrames: UInt32 = 4096,
        format: AudioStreamFormatDescription? = nil,
        reusing previousChain: AUEffectChain? = nil
    ) {
        self.entries = entries
        self.format = format ?? AudioStreamFormatDescription(sampleRate: sampleRate, frameCapacity: maxFrames, channelCount: 2, isInterleaved: false)

        var allHosts: [AUEffectHost] = []
        var groups: [[AUEffectHost]] = []
        var failed = Set<UUID>()
        var unsupported = Set<UUID>()

        for entry in entries {
            // Keep an unchanged AU instance alive when a chain snapshot is
            // replaced. Some third-party AUs (notably editor-heavy effects)
            // do not reliably resume rendering after being uninitialized and
            // immediately reinitialized while audio is running.
            if let reusableGroup = Self.reusableHostGroup(for: entry, in: previousChain, format: self.format),
               reusableGroup.first?.format == self.format {
                for host in reusableGroup { host.setEnabled(entry.isEnabled) }
                groups.append(reusableGroup)
                allHosts.append(contentsOf: reusableGroup)
                if reusableGroup.count == 1, !reusableGroup[0].canProcessCurrentLayout {
                    unsupported.insert(entry.id)
                }
                continue
            }

            let native = AUEffectHost(
                descriptor: entry.pluginDescriptor,
                entryID: entry.id,
                sampleRate: self.format.sampleRate,
                maxFrames: maxFrames,
                enabled: entry.isEnabled,
                format: self.format,
                processingMode: entry.processingMode
            )
            guard native.instantiate() else {
                failed.insert(entry.id)
                groups.append([])
                continue
            }

            let wantsIndependent = entry.processingMode == .independentPerChannel ||
                (entry.processingMode == .auto && self.format.channelCount > 2 && !native.canProcessCurrentLayout)

            if wantsIndependent && self.format.channelCount > 1 {
                let monoFormat = AudioStreamFormatDescription(
                    sampleRate: self.format.sampleRate,
                    frameCapacity: self.format.frameCapacity,
                    channelCount: 1,
                    isInterleaved: false,
                    channelLayoutTag: kAudioChannelLayoutTag_Mono
                )
                var monos: [AUEffectHost] = []
                for _ in 0..<self.format.channelCount {
                    let mono = AUEffectHost(
                        descriptor: entry.pluginDescriptor,
                        entryID: entry.id,
                        sampleRate: self.format.sampleRate,
                        maxFrames: maxFrames,
                        enabled: entry.isEnabled,
                        format: monoFormat,
                        processingMode: .independentPerChannel
                    )
                    guard mono.instantiate(), mono.canProcessCurrentLayout else {
                        monos.removeAll()
                        break
                    }
                    if let preset = entry.presetData { _ = mono.loadPreset(preset) }
                    else if let index = entry.selectedFactoryPresetIndex { _ = mono.selectFactoryPreset(index: index) }
                    monos.append(mono)
                }
                if monos.count == self.format.channelCount {
                    native.setEnabled(false)
                    groups.append(monos)
                    allHosts.append(contentsOf: monos)
                    continue
                }
            }

            if !native.canProcessCurrentLayout {
                unsupported.insert(entry.id)
            }
            if let preset = entry.presetData { _ = native.loadPreset(preset) }
            else if let index = entry.selectedFactoryPresetIndex { _ = native.selectFactoryPreset(index: index) }
            groups.append([native])
            allHosts.append(native)
        }

        self.failedEntryIDs = failed
        self.unsupportedEntryIDs = unsupported
        self._hosts = allHosts
        self.hostGroups = groups
        self.hostGroupsByEntryID = Dictionary(
            zip(entries, groups).map { ($0.0.id, $0.1) },
            uniquingKeysWith: { _, latest in latest }
        )
        for host in allHosts { CrashGuard.trackPlugin(host.descriptor.id) }
        logger.info("Created AU chain with \(allHosts.count) host instances for \(self.format.shortLabel)")
    }

    private static func reusableHostGroup(
        for entry: AUEffectChainEntry,
        in previousChain: AUEffectChain?,
        format: AudioStreamFormatDescription
    ) -> [AUEffectHost]? {
        guard let previousChain,
              let previousIndex = previousChain.entries.firstIndex(where: { $0.id == entry.id }),
              let previousGroup = previousChain.hostGroupsByEntryID[entry.id],
              !previousGroup.isEmpty,
              previousChain.entries[previousIndex].pluginDescriptor == entry.pluginDescriptor,
              previousChain.entries[previousIndex].processingMode == entry.processingMode,
              previousChain.entries[previousIndex].channelSelection == entry.channelSelection,
              previousGroup.allSatisfy({ $0.format == format }) else { return nil }

        // A changed preset is deliberately rebuilt on the main thread so the
        // new configuration is applied before the instance reaches audio.
        guard previousChain.entries[previousIndex].presetData == entry.presetData,
              previousChain.entries[previousIndex].selectedFactoryPresetIndex == entry.selectedFactoryPresetIndex else {
            return nil
        }

        let expectsIndependentHosts = entry.processingMode == .independentPerChannel ||
            (entry.processingMode == .auto && format.channelCount > 2 && previousGroup.count > 1)
        let hasExpectedShape = expectsIndependentHosts
            ? previousGroup.count == format.channelCount
            : previousGroup.count == 1
        return hasExpectedShape ? previousGroup : nil
    }

    func setBypassed(_ bypassed: Bool) { _isBypassed = bypassed }

    func host(for entryID: UUID) -> AUEffectHost? {
        _hosts.first { $0.entryID == entryID }
    }

    /// Processes a complete buffer list so interleaved and non-interleaved
    /// layouts retain their exact channel order.
    @inline(__always)
    func processBuffers(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard !_isBypassed else { return }
        var groupIndex = 0
        for group in hostGroups {
            guard !group.isEmpty else { groupIndex += 1; continue }
            if group.count == 1 {
                group[0].renderBuffers(buffers, frameCount: frameCount)
            } else {
                processIndependent(group, buffers: buffers, frameCount: frameCount)
            }
            groupIndex += 1
        }
    }

    /// Backwards-compatible stereo test/API helper.
    @inline(__always)
    func processInterleaved(samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !_isBypassed else { return }
        for group in hostGroups {
            if group.count == 1 { group[0].renderInterleaved(samples: samples, frameCount: frameCount) }
            else if group.count == 2 {
                group[0].renderChannel(samples: samples, frameCount: frameCount, stride: 2)
                group[1].renderChannel(samples: samples.advanced(by: 1), frameCount: frameCount, stride: 2)
            }
        }
    }

    @inline(__always)
    private func processIndependent(_ group: [AUEffectHost], buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        var channel = 0
        for buffer in buffers {
            guard let data = buffer.mData else { channel += max(1, Int(buffer.mNumberChannels)); continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = data.assumingMemoryBound(to: Float.self)
            for local in 0..<channels where channel + local < group.count {
                group[channel + local].renderChannel(samples: samples.advanced(by: local), frameCount: frameCount, stride: channels)
            }
            channel += channels
        }
    }
}
