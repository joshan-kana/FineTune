import AudioToolbox
import Darwin
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
    private let hostGroupsEnabled: [Bool]
    private nonisolated(unsafe) var _isBypassed = false
    private nonisolated(unsafe) var _isRetiring = false
    private nonisolated(unsafe) var _activeRenderCount: Int32 = 0
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AUEffectChain")

    var isBypassed: Bool { _isBypassed }
    var hosts: [AUEffectHost] { _hosts }
    var maxTailTime: Double {
        AUEffectChainTopology.serialSum(
            hostGroups.map { $0.map(\.tailTimeSeconds) },
            enabled: hostGroupsEnabled
        )
    }
    var aggregateLatencySeconds: Double {
        AUEffectChainTopology.serialSum(
            hostGroups.map { $0.map(\.latencySeconds) },
            enabled: hostGroupsEnabled
        )
    }

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
        var enabledGroups: [Bool] = []
        var failed = Set<UUID>()
        var unsupported = Set<UUID>()

        for entry in entries {
            // Keep an unchanged AU instance alive when a chain snapshot is
            // replaced. Some third-party AUs (notably editor-heavy effects)
            // do not reliably resume rendering after being uninitialized and
            // immediately reinitialized while audio is running.
            if let reusableGroup = Self.reusableHostGroup(for: entry, in: previousChain, format: self.format),
               reusableGroup.first?.format == self.format {
                groups.append(reusableGroup)
                enabledGroups.append(entry.isEnabled)
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
                enabledGroups.append(false)
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
                    enabledGroups.append(entry.isEnabled)
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
            enabledGroups.append(entry.isEnabled)
            allHosts.append(native)
        }

        self.failedEntryIDs = failed
        self.unsupportedEntryIDs = unsupported
        self._hosts = allHosts
        self.hostGroups = groups
        self.hostGroupsEnabled = enabledGroups
        self.hostGroupsByEntryID = Dictionary(
            zip(entries, groups).map { ($0.0.id, $0.1) },
            uniquingKeysWith: { _, latest in latest }
        )
        for (index, group) in groups.enumerated() where !group.isEmpty {
            AUEffectPeerRegistry.shared.register(group, entryID: entries[index].id)
        }
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

    /// Prevents this snapshot from starting another Audio Unit render during
    /// replacement. Existing callbacks are allowed to finish; later calls
    /// fail open until the replacement becomes current.
    func beginRetirement() {
        OSMemoryBarrier()
        _isRetiring = true
        OSMemoryBarrier()
    }

    func waitForRenderQuiescence() {
        while true {
            OSMemoryBarrier()
            if _activeRenderCount == 0 { return }
            sched_yield()
        }
    }

    func host(for entryID: UUID) -> AUEffectHost? {
        _hosts.first { $0.entryID == entryID }
    }

    func hosts(for entryID: UUID) -> [AUEffectHost] {
        hostGroupsByEntryID[entryID] ?? []
    }

    func isEntryEnabled(_ entryID: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        return hostGroupsEnabled[index]
    }

    var logicalEntryLatencies: [Double] {
        hostGroups.enumerated().map { index, group in
            guard hostGroupsEnabled[index] else { return 0 }
            return group.map(\.latencySeconds).max() ?? 0
        }
    }

    var logicalEntryTails: [Double] {
        hostGroups.enumerated().map { index, group in
            guard hostGroupsEnabled[index] else { return 0 }
            return group.map(\.tailTimeSeconds).max() ?? 0
        }
    }

    /// Processes a complete buffer list so interleaved and non-interleaved
    /// layouts retain their exact channel order.
    @inline(__always)
    func processBuffers(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard !_isBypassed, beginRender() else { return }
        defer { endRender() }
        var groupIndex = 0
        for group in hostGroups {
            guard !group.isEmpty, hostGroupsEnabled[groupIndex] else { groupIndex += 1; continue }
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
        guard !_isBypassed, beginRender() else { return }
        defer { endRender() }
        for group in hostGroups {
            if group.count == 1 { group[0].renderInterleaved(samples: samples, frameCount: frameCount) }
            else if group.count == 2 {
                group[0].renderChannel(samples: samples, frameCount: frameCount, stride: 2)
                group[1].renderChannel(samples: samples.advanced(by: 1), frameCount: frameCount, stride: 2)
            }
        }
    }

    @inline(__always)
    private func beginRender() -> Bool {
        OSMemoryBarrier()
        guard !_isRetiring else { return false }
        OSAtomicIncrement32Barrier(&_activeRenderCount)
        OSMemoryBarrier()
        if _isRetiring {
            OSAtomicDecrement32Barrier(&_activeRenderCount)
            return false
        }
        return true
    }

    @inline(__always)
    private func endRender() {
        OSAtomicDecrement32Barrier(&_activeRenderCount)
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

enum AUEffectChainTopology {
    static func parallelMaximum(_ values: [Double], enabled: Bool = true) -> Double {
        enabled ? (values.max() ?? 0) : 0
    }

    static func serialSum(_ groups: [[Double]], enabled: [Bool]) -> Double {
        zip(groups, enabled).reduce(0) { total, pair in
            total + parallelMaximum(pair.0, enabled: pair.1)
        }
    }
}

/// Coordinates parameter changes for every concrete host belonging to one
/// logical entry. Audio Unit event delivery is throttled and handled on a
/// serial utility queue, never from the render callback.
final class AUEffectPeerRegistry: @unchecked Sendable {
    static let shared = AUEffectPeerRegistry()

    private let lock = NSLock()
    private var coordinators: [UUID: AUEffectPeerCoordinator] = [:]

    func register(_ hosts: [AUEffectHost], entryID: UUID) {
        guard !hosts.isEmpty else { return }
        let coordinator: AUEffectPeerCoordinator
        lock.lock()
        if let existing = coordinators[entryID] {
            coordinator = existing
        } else {
            coordinator = AUEffectPeerCoordinator()
            coordinators[entryID] = coordinator
        }
        lock.unlock()
        coordinator.register(hosts)
    }

    func reconcile(entryID: UUID, source: AUEffectHost) {
        lock.lock()
        let coordinator = coordinators[entryID]
        lock.unlock()
        coordinator?.reconcile(source: source)
    }
}

private final class AUEffectPeerCoordinator: @unchecked Sendable {
    private struct ParameterKey: Hashable {
        let hostID: ObjectIdentifier
        let parameterID: AudioUnitParameterID
        let scope: AudioUnitScope
        let element: AudioUnitElement
    }

    private final class WeakHost {
        weak var value: AUEffectHost?
        init(_ value: AUEffectHost) { self.value = value }
    }

    private let queue = DispatchQueue(label: "FineTune.AUEffectPeerCoordinator", qos: .utility)
    private var hosts: [WeakHost] = []
    private var suppressed: [ParameterKey: AudioUnitParameterValue] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AUEffectPeerCoordinator")

    func register(_ newHosts: [AUEffectHost]) {
        queue.sync { [weak self] in
            guard let self else { return }
            self.hosts.removeAll { $0.value == nil }
            for host in newHosts where !self.hosts.contains(where: { $0.value === host }) {
                self.hosts.append(WeakHost(host))
                host.installParameterObserver { [weak self, weak host] parameter, value in
                    guard let self, let host else { return }
                    self.parameterChanged(from: host, parameter: parameter, value: value)
                }
            }
        }
    }

    func reconcile(source: AUEffectHost) {
        queue.sync {
            hosts.removeAll { $0.value == nil }
            guard let state = source.savePreset() else { return }
            for weakHost in hosts {
                guard let host = weakHost.value, host !== source else { continue }
                _ = host.loadPreset(state)
            }
        }
    }

    private func parameterChanged(from source: AUEffectHost, parameter: AudioUnitParameter, value: AudioUnitParameterValue) {
        let parameterID = parameter.mParameterID
        let scope = parameter.mScope
        let element = parameter.mElement
        queue.async { [weak self] in
            guard let self else { return }
            self.hosts.removeAll { $0.value == nil }
            let key = ParameterKey(
                hostID: ObjectIdentifier(source),
                parameterID: parameterID,
                scope: scope,
                element: element
            )
            if let expected = self.suppressed.removeValue(forKey: key), abs(expected - value) < 0.0001 {
                return
            }

            for weakHost in self.hosts {
                guard let host = weakHost.value, host !== source, let au = host.audioUnit else { continue }
                let peerKey = ParameterKey(
                    hostID: ObjectIdentifier(host),
                    parameterID: parameterID,
                    scope: scope,
                    element: element
                )
                self.suppressed[peerKey] = value
                var peerParameter = AudioUnitParameter(
                    mAudioUnit: au,
                    mParameterID: parameterID,
                    mScope: scope,
                    mElement: element
                )
                let status = AUParameterSet(nil, nil, &peerParameter, value, 0)
                if status != noErr {
                    self.suppressed.removeValue(forKey: peerKey)
                    self.logger.warning("Failed to mirror AU parameter \(parameterID): \(status)")
                }
            }
        }
    }
}
