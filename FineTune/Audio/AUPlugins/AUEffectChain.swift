import AudioToolbox
import Darwin
import Foundation
import os
import Synchronization

/// Lock-free ownership handoff for one immutable render snapshot.
///
/// The HAL callback is the only writer of `activeRenders`; the owner of a
/// snapshot publishes retirement from a non-render context (the main actor
/// for chains, a utility queue for host state mutation). Publication uses
/// release stores and callback entry uses acquire loads/CAS. A retiring snapshot rejects new
/// renders, waits at most `maximumWait`, and is never destroyed until the
/// active count reaches zero. This keeps the callback allocation-free,
/// lock-free, and free of blocking calls while ensuring the main actor cannot
/// wait forever on a third-party Audio Unit.
final class AUEffectRenderHandoff: @unchecked Sendable {
    static let maximumWait: TimeInterval = 0.100

    private let retiring = Atomic<Bool>(false)
    private let activeRenders = Atomic<Int32>(0)
    private let retirementToken = Atomic<UInt64>(0)

    @inline(__always)
    func beginRetirement() -> UInt64 {
        let token = nextToken()
        retiring.store(true, ordering: .releasing)
        return token
    }

    @inline(__always)
    func cancelRetirement(ifToken token: UInt64) {
        guard retirementToken.load(ordering: .acquiring) == token else { return }
        retiring.store(false, ordering: .releasing)
    }

    @inline(__always)
    func beginRender() -> Bool {
        guard !retiring.load(ordering: .acquiring) else { return false }
        incrementActive()
        guard !retiring.load(ordering: .acquiring) else {
            decrementActive()
            return false
        }
        return true
    }

    @inline(__always)
    func endRender() {
        decrementActive()
    }

    func waitForQuiescence(timeout: TimeInterval = 0.100) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        while activeRenders.load(ordering: .acquiring) != 0 {
            if DispatchTime.now().uptimeNanoseconds >= deadline { return false }
            sched_yield()
        }
        return true
    }

    var activeRenderCount: Int32 { activeRenders.load(ordering: .acquiring) }

    private func nextToken() -> UInt64 {
        while true {
            let current = retirementToken.load(ordering: .acquiring)
            let result = retirementToken.compareExchange(
                expected: current,
                desired: current &+ 1,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { return current &+ 1 }
        }
    }

    @inline(__always)
    private func incrementActive() {
        while true {
            let current = activeRenders.load(ordering: .relaxed)
            let result = activeRenders.compareExchange(
                expected: current,
                desired: current &+ 1,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { return }
        }
    }

    @inline(__always)
    private func decrementActive() {
        while true {
            let current = activeRenders.load(ordering: .relaxed)
            let result = activeRenders.compareExchange(
                expected: current,
                desired: current &- 1,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { return }
        }
    }
}

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
    let topologies: [AUProcessingTopology]

    private let _hosts: [AUEffectHost]
    private let hostGroups: [[AUEffectHost]]
    private let hostGroupsByEntryID: [UUID: [AUEffectHost]]
    private let hostGroupsEnabled: [Bool]
    private let ownerID = UUID()
    private nonisolated(unsafe) var _isBypassed = false
    private let renderHandoff = AUEffectRenderHandoff()
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
        var selectedTopologies: [AUProcessingTopology] = []
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
                selectedTopologies.append(previousChain?.topology(for: entry.id) ?? .native)
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
            // A third-party AU may reject the native HDMI layout during
            // stream-format negotiation or initialization while still
            // supporting a safe mono fallback. Keep the capability metadata
            // gathered before that rejection and try the fallback before
            // declaring the entry failed.
            let nativeInstantiated = native.instantiate()
            let topology = AUProcessingTopology.choose(
                mode: entry.processingMode,
                channelCount: self.format.channelCount,
                nativeCanProcess: nativeInstantiated && native.canProcessCurrentLayout,
                supportedChannelCounts: native.supportedChannelCounts,
                hasFrontStereoPair: self.format.frontStereoChannelIndices != nil
            )

            if topology == .independentPerChannel && self.format.channelCount > 1 {
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
                    if let preset = entry.presetData {
                        _ = mono.loadPreset(preset)
                    } else if let index = entry.selectedFactoryPresetIndex {
                        _ = mono.selectFactoryPreset(index: index)
                    }
                    monos.append(mono)
                }
                if monos.count == self.format.channelCount {
                    if nativeInstantiated {
                        native.setEnabled(false)
                    }
                    groups.append(monos)
                    enabledGroups.append(entry.isEnabled)
                    selectedTopologies.append(.independentPerChannel)
                    allHosts.append(contentsOf: monos)
                    continue
                }
            }

            if topology == .frontStereoPassThrough,
               self.format.frontStereoChannelIndices != nil {
                let stereoFormat = AudioStreamFormatDescription(
                    sampleRate: self.format.sampleRate,
                    frameCapacity: self.format.frameCapacity,
                    channelCount: 2,
                    isInterleaved: false,
                    channelLayoutTag: kAudioChannelLayoutTag_Stereo
                )
                let stereoHost = AUEffectHost(
                    descriptor: entry.pluginDescriptor,
                    entryID: entry.id,
                    sampleRate: self.format.sampleRate,
                    maxFrames: maxFrames,
                    enabled: entry.isEnabled,
                    format: stereoFormat,
                    processingMode: .stereoOnly
                )
                if stereoHost.instantiate(), stereoHost.canProcessCurrentLayout {
                    if let preset = entry.presetData {
                        _ = stereoHost.loadPreset(preset)
                    } else if let index = entry.selectedFactoryPresetIndex {
                        _ = stereoHost.selectFactoryPreset(index: index)
                    }
                    groups.append([stereoHost])
                    enabledGroups.append(entry.isEnabled)
                    selectedTopologies.append(.frontStereoPassThrough)
                    allHosts.append(stereoHost)
                    continue
                }
                // Keep the native instance, if any, only long enough for its
                // state to be released. A rejected stereo fallback is a
                // visible unsupported entry and remains fail-open.
                unsupported.insert(entry.id)
            }

            if !nativeInstantiated || topology == .unsupported || !native.canProcessCurrentLayout {
                unsupported.insert(entry.id)
            }
            if nativeInstantiated {
                if let preset = entry.presetData {
                    _ = native.loadPreset(preset)
                } else if let index = entry.selectedFactoryPresetIndex {
                    _ = native.selectFactoryPreset(index: index)
                }
                groups.append([native])
                enabledGroups.append(entry.isEnabled)
                selectedTopologies.append(
                    topology == .native && native.canProcessCurrentLayout ? .native : .unsupported
                )
                allHosts.append(native)
            } else {
                failed.insert(entry.id)
                groups.append([])
                enabledGroups.append(false)
                selectedTopologies.append(.unsupported)
            }
        }

        // Unsupported layouts are a visible failure too: their hosts remain
        // fail-open, but the UI must not imply that the AU is processing.
        self.failedEntryIDs = failed.union(unsupported)
        self.unsupportedEntryIDs = unsupported
        self.topologies = selectedTopologies
        self._hosts = allHosts
        self.hostGroups = groups
        self.hostGroupsEnabled = enabledGroups
        self.hostGroupsByEntryID = Dictionary(
            zip(entries, groups).map { ($0.0.id, $0.1) },
            uniquingKeysWith: { _, latest in latest }
        )
        for (index, group) in groups.enumerated() where !group.isEmpty {
            AUEffectPeerRegistry.shared.register(group, entryID: entries[index].id, ownerID: ownerID)
        }
        for host in allHosts { CrashGuard.trackPlugin(host.descriptor.id) }
        logger.info("Created AU chain with \(allHosts.count) host instances for \(self.format.shortLabel)")
    }

    deinit {
        for (index, group) in hostGroups.enumerated() where !group.isEmpty {
            AUEffectPeerRegistry.shared.unregister(group, entryID: entries[index].id, ownerID: ownerID)
        }
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

    func canReuseHost(for entry: AUEffectChainEntry, format: AudioStreamFormatDescription? = nil) -> Bool {
        Self.reusableHostGroup(for: entry, in: self, format: format ?? self.format) != nil
    }

    func setBypassed(_ bypassed: Bool) { _isBypassed = bypassed }

    /// Prevents this snapshot from starting another Audio Unit render during
    /// replacement. Existing callbacks are allowed to finish; later calls
    /// fail open until the replacement becomes current.
    @discardableResult
    func beginRetirement() -> UInt64 {
        renderHandoff.beginRetirement()
    }

    func cancelRetirement(ifToken token: UInt64) {
        renderHandoff.cancelRetirement(ifToken: token)
    }

    func waitForRenderQuiescence(timeout: TimeInterval = 0.100) -> Bool {
        renderHandoff.waitForQuiescence(timeout: timeout)
    }

    #if DEBUG
    @discardableResult
    func beginRenderForTesting() -> Bool {
        renderHandoff.beginRender()
    }

    func endRenderForTesting() {
        renderHandoff.endRender()
    }
    #endif

    func host(for entryID: UUID) -> AUEffectHost? {
        _hosts.first { $0.entryID == entryID }
    }

    func hosts(for entryID: UUID) -> [AUEffectHost] {
        hostGroupsByEntryID[entryID] ?? []
    }

    func topology(for entryID: UUID) -> AUProcessingTopology {
        guard let index = entries.firstIndex(where: { $0.id == entryID }), index < topologies.count else {
            return .unsupported
        }
        return topologies[index]
    }

    func topologyDescription(for entryID: UUID) -> String {
        switch topology(for: entryID) {
        case .native: return format.isMultichannel ? "Native multichannel" : "Native stereo"
        case .independentPerChannel: return "Independent mono hosts ×\(format.channelCount)"
        case .frontStereoPassThrough: return "Front L/R stereo • other channels unchanged"
        case .unsupported: return "Unsupported layout • audio preserved"
        }
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
            if topologies[groupIndex] == .frontStereoPassThrough,
               let channelIndices = format.frontStereoChannelIndices {
                group[0].renderFrontStereo(
                    buffers: buffers,
                    frameCount: frameCount,
                    channelIndices: channelIndices
                )
            } else if group.count == 1 {
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
        for (groupIndex, group) in hostGroups.enumerated() {
            guard hostGroupsEnabled[groupIndex] else { continue }
            if group.count == 1 { group[0].renderInterleaved(samples: samples, frameCount: frameCount) }
            else if group.count == 2 {
                group[0].renderChannel(samples: samples, frameCount: frameCount, stride: 2)
                group[1].renderChannel(samples: samples.advanced(by: 1), frameCount: frameCount, stride: 2)
            }
        }
    }

    @inline(__always)
    private func beginRender() -> Bool {
        renderHandoff.beginRender()
    }

    @inline(__always)
    private func endRender() {
        renderHandoff.endRender()
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

    #if DEBUG
    var coordinatorCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return coordinators.count
    }

    func hostCountForTesting(entryID: UUID) -> Int {
        lock.lock()
        let coordinator = coordinators[entryID]
        lock.unlock()
        return coordinator?.hostCount ?? 0
    }

    func emitParameterChangeForTesting(
        entryID: UUID,
        source: AUEffectHost,
        parameterID: AudioUnitParameterID,
        scope: AudioUnitScope = kAudioUnitScope_Global,
        element: AudioUnitElement = 0,
        value: AudioUnitParameterValue
    ) {
        lock.lock()
        let coordinator = coordinators[entryID]
        lock.unlock()
        coordinator?.parameterChangedForTesting(
            from: source,
            parameterID: parameterID,
            scope: scope,
            element: element,
            value: value
        )
    }
    #endif

    func register(_ hosts: [AUEffectHost], entryID: UUID, ownerID: UUID) {
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
        coordinator.register(hosts, ownerID: ownerID)
    }

    func unregister(_ hosts: [AUEffectHost], entryID: UUID, ownerID: UUID) {
        lock.lock()
        let coordinator = coordinators[entryID]
        lock.unlock()
        guard let coordinator else { return }
        coordinator.unregisterAsync(hosts, ownerID: ownerID) { [weak self, weak coordinator] in
            guard let self, let coordinator, coordinator.isEmpty else { return }
            self.lock.lock()
            if self.coordinators[entryID] === coordinator {
                self.coordinators.removeValue(forKey: entryID)
            }
            self.lock.unlock()
        }
    }

    #if DEBUG
    func unregisterSynchronouslyForTesting(_ hosts: [AUEffectHost], entryID: UUID, ownerID: UUID) {
        lock.lock()
        let coordinator = coordinators[entryID]
        lock.unlock()
        guard let coordinator else { return }
        coordinator.unregister(hosts, ownerID: ownerID)
        if coordinator.isEmpty {
            lock.lock()
            if coordinators[entryID] === coordinator {
                coordinators.removeValue(forKey: entryID)
            }
            lock.unlock()
        }
    }
    #endif

    func reconcile(entryID: UUID, source: AUEffectHost) {
        lock.lock()
        let coordinator = coordinators[entryID]
        lock.unlock()
        coordinator?.reconcileAsync(source: source)
    }

    /// Used only after the owning chain has reached quiescence on a utility
    /// thread. The synchronous wait is deliberately unavailable to the main
    /// actor and never runs from the render callback.
    func reconcileSynchronously(entryID: UUID, source: AUEffectHost) {
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
    private var owners: [ObjectIdentifier: Set<UUID>] = [:]
    private var suppressed: [ParameterKey: AudioUnitParameterValue] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AUEffectPeerCoordinator")

    func register(_ newHosts: [AUEffectHost], ownerID: UUID) {
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
            for host in newHosts {
                owners[ObjectIdentifier(host), default: []].insert(ownerID)
            }
        }
    }

    func unregister(_ oldHosts: [AUEffectHost], ownerID: UUID) {
        queue.sync {
            unregisterOnQueue(oldHosts, ownerID: ownerID)
        }
    }

    func unregisterAsync(
        _ oldHosts: [AUEffectHost],
        ownerID: UUID,
        completion: @escaping @Sendable () -> Void
    ) {
        queue.async { [weak self] in
            self?.unregisterOnQueue(oldHosts, ownerID: ownerID)
            DispatchQueue.global(qos: .utility).async(execute: completion)
        }
    }

    private func unregisterOnQueue(_ oldHosts: [AUEffectHost], ownerID: UUID) {
        for host in oldHosts {
            let id = ObjectIdentifier(host)
            owners[id]?.remove(ownerID)
            if owners[id]?.isEmpty == true {
                owners.removeValue(forKey: id)
            }
        }
        hosts.removeAll { host in
            guard let value = host.value else { return true }
            return owners[ObjectIdentifier(value)] == nil
        }
        suppressed = suppressed.filter { key, _ in
            hosts.contains { weakHost in
                guard let value = weakHost.value else { return false }
                return ObjectIdentifier(value) == key.hostID
            }
        }
    }

    var isEmpty: Bool {
        queue.sync {
            hosts.removeAll { $0.value == nil }
            return hosts.isEmpty
        }
    }

    var hostCount: Int {
        queue.sync {
            hosts.removeAll { $0.value == nil }
            return hosts.count
        }
    }

    func reconcileAsync(source: AUEffectHost) {
        queue.async { [weak self] in
            self?.reconcileOnQueue(source: source)
        }
    }

    func reconcile(source: AUEffectHost) {
        queue.sync { reconcileOnQueue(source: source) }
    }

    private func reconcileOnQueue(source: AUEffectHost) {
        hosts.removeAll { $0.value == nil }
        guard let state = source.savePreset() else { return }
        for weakHost in hosts {
            guard let host = weakHost.value, host !== source else { continue }
            _ = host.loadPresetSafely(state)
        }
    }

    private func parameterChanged(from source: AUEffectHost, parameter: AudioUnitParameter, value: AudioUnitParameterValue) {
        parameterChanged(
            from: source,
            parameterID: parameter.mParameterID,
            scope: parameter.mScope,
            element: parameter.mElement,
            value: value
        )
    }

    #if DEBUG
    func parameterChangedForTesting(
        from source: AUEffectHost,
        parameterID: AudioUnitParameterID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        value: AudioUnitParameterValue
    ) {
        parameterChanged(
            from: source,
            parameterID: parameterID,
            scope: scope,
            element: element,
            value: value
        )
    }
    #endif

    private func parameterChanged(
        from source: AUEffectHost,
        parameterID: AudioUnitParameterID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        value: AudioUnitParameterValue
    ) {
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
                guard let host = weakHost.value, host !== source else { continue }
                let peerKey = ParameterKey(
                    hostID: ObjectIdentifier(host),
                    parameterID: parameterID,
                    scope: scope,
                    element: element
                )
                self.suppressed[peerKey] = value
                let status = self.setParameter(
                    on: host,
                    parameterID: parameterID,
                    scope: scope,
                    element: element,
                    value: value
                )
                if status != noErr {
                    self.suppressed.removeValue(forKey: peerKey)
                    self.logger.warning("Failed to mirror AU parameter \(parameterID): \(status)")
                }
            }
        }
    }

    private func setParameter(
        on host: AUEffectHost,
        parameterID: AudioUnitParameterID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        value: AudioUnitParameterValue
    ) -> OSStatus {
        #if DEBUG
        if let testStatus = host.applyPeerParameterForTesting(value) {
            return testStatus
        }
        #endif
        guard let au = host.audioUnit else { return -1 }
        var parameter = AudioUnitParameter(
            mAudioUnit: au,
            mParameterID: parameterID,
            mScope: scope,
            mElement: element
        )
        return AUParameterSet(nil, nil, &parameter, value, 0)
    }
}
