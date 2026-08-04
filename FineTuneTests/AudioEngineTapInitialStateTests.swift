// FineTuneTests/AudioEngineTapInitialStateTests.swift
//
// Verifies AudioEngine derives TapInitialState from persisted settings and
// hands it to activate(initial:) before any post-activation mutation.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

// MARK: - Recording Mock

/// Records every method invocation against `ProcessTapControlling` in order.
/// Tests assert on `events` to verify the engine's apply-initial-state contract.
@MainActor
final class RecordingProcessTapController: ProcessTapControlling {
    enum Event: Equatable {
        case activate(TapInitialStateSnapshot)
        case updateEQSettings(EQSettings)
        case updateAutoEQProfile(profileID: String?)
        case setAutoEQPreampEnabled(Bool)
        case updateLoudnessCompensation(volume: Float, enabled: Bool)
        case updateLoudnessEqualization(LoudnessEqualizerSettings)
        case updateAUEffectChain([AUEffectChainEntry])
        case updateDeviceAUEffectChain([AUEffectChainEntry])
        case invalidate
    }

    /// Plain snapshot of `TapInitialState` so test asserts don't depend on
    /// the source-type's identity (defensive against future mutations).
    struct TapInitialStateSnapshot: Equatable {
        var eqSettings: EQSettings
        var autoEQProfileID: String?
        var autoEQPreampEnabled: Bool
        var loudnessVolume: Float
        var loudnessCompensationEnabled: Bool
        var loudnessEqualizerSettings: LoudnessEqualizerSettings

        @MainActor
        init(_ s: TapInitialState) {
            self.eqSettings = s.eqSettings
            self.autoEQProfileID = s.autoEQProfile?.id
            self.autoEQPreampEnabled = s.autoEQPreampEnabled
            self.loudnessVolume = s.loudnessVolume
            self.loudnessCompensationEnabled = s.loudnessCompensationEnabled
            self.loudnessEqualizerSettings = s.loudnessEqualizerSettings
        }
    }

    let app: AudioApp
    private(set) var events: [Event] = []
    var appAUResult: AUChainUpdateResult = .committed
    var deviceAUResult: AUChainUpdateResult = .committed
    var deferAUCompletions = false
    private(set) var pendingAppAUCompletions: [@MainActor @Sendable (AUChainUpdateResult) -> Void] = []
    private(set) var pendingDeviceAUCompletions: [@MainActor @Sendable (AUChainUpdateResult) -> Void] = []
    private var lastAppAUCompletion: (@MainActor @Sendable (AUChainUpdateResult) -> Void)?

    // Mutable surface — recorded as plain property writes (not events).
    var volume: Float = 1.0
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted: Bool = false
    var audioLevel: Float = 0.0
    private(set) var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String? = nil

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func activate(initial: TapInitialState) throws {
        events.append(.activate(TapInitialStateSnapshot(initial)))
    }

    func invalidate() {
        events.append(.invalidate)
    }

    func updateEQSettings(_ settings: EQSettings) {
        events.append(.updateEQSettings(settings))
    }

    func updateAutoEQProfile(_ profile: AutoEQProfile?) {
        events.append(.updateAutoEQProfile(profileID: profile?.id))
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        events.append(.setAutoEQPreampEnabled(enabled))
    }

    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        events.append(.updateLoudnessCompensation(volume: volume, enabled: enabled))
    }

    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {
        events.append(.updateLoudnessEqualization(settings))
    }

    func updateAUEffectChain(_ entries: [AUEffectChainEntry]) {}

    func updateAUEffectChain(
        _ entries: [AUEffectChainEntry],
        completion: @escaping @MainActor @Sendable (AUChainUpdateResult) -> Void
    ) {
        events.append(.updateAUEffectChain(entries))
        lastAppAUCompletion = completion
        if deferAUCompletions {
            pendingAppAUCompletions.append(completion)
        } else {
            completion(appAUResult)
        }
    }

    func updateDeviceAUEffectChain(_ entries: [AUEffectChainEntry]) {}

    func updateDeviceAUEffectChain(
        _ entries: [AUEffectChainEntry],
        completion: @escaping @MainActor @Sendable (AUChainUpdateResult) -> Void
    ) {
        events.append(.updateDeviceAUEffectChain(entries))
        if deferAUCompletions {
            pendingDeviceAUCompletions.append(completion)
        } else {
            completion(deviceAUResult)
        }
    }

    func completeNextAppAU(_ result: AUChainUpdateResult) {
        guard !pendingAppAUCompletions.isEmpty else { return }
        pendingAppAUCompletions.removeFirst()(result)
    }

    func repeatLastAppAUCompletion(_ result: AUChainUpdateResult) {
        lastAppAUCompletion?(result)
    }

    func completeNextDeviceAU(_ result: AUChainUpdateResult) {
        guard !pendingDeviceAUCompletions.isEmpty else { return }
        pendingDeviceAUCompletions.removeFirst()(result)
    }

    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = [newDeviceUID]
    }

    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = newDeviceUIDs
    }

    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {}
}

// MARK: - Process monitor stub

@MainActor
final class StubProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?
    func start() {}
    func stop() {}
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let deviceMonitor: MockAudioDeviceMonitor
    let deviceVolume: MockDeviceVolumeProviding
    let app: AudioApp
    let device: AudioDevice
    let lastTap: () -> RecordingProcessTapController?
    let allTaps: () -> [RecordingProcessTapController]
}

@MainActor
private func makeFixture(
    supportsAutoEQ: Bool = true,
    deviceVolume: Float = 0.75
) -> Fixture {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)

    let deviceMonitor = MockAudioDeviceMonitor()
    let device = AudioDevice(
        id: AudioDeviceID(99),
        uid: "uid-test",
        name: "Test Output",
        icon: nil,
        supportsAutoEQ: supportsAutoEQ
    )
    deviceMonitor.addOutputDevice(device)

    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    mockVolume.volumes[device.id] = deviceVolume

    let app = AudioApp(
        id: 12345,
        processObjectIDs: [],
        name: "TestApp",
        icon: NSImage(),
        bundleID: "com.test.tapinitial"
    )

    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = [app]

    // Capture every tap the factory hands out so tests can read the captured
    // event log. Mutable box lets the closure write into the test scope.
    let box = TapBox()

    // ensureTapExists guards on permission.status == .authorized. The TCC SPI
    // preflight returns -1 (unknown) under xctest, so we force it to authorized
    // via the internal(set) status property exposed by @testable import.
    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: mockVolume,
        tapFactory: { app, uids, _ in
            let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
            box.last = tap
            box.all.append(tap)
            return tap
        },
        startMonitorsAutomatically: false
    )

    return Fixture(
        engine: engine,
        settings: settings,
        deviceMonitor: deviceMonitor,
        deviceVolume: mockVolume,
        app: app,
        device: device,
        lastTap: { box.last },
        allTaps: { box.all }
    )
}

@MainActor
private final class TapBox {
    var last: RecordingProcessTapController?
    var all: [RecordingProcessTapController] = []
}

// MARK: - Suite

@Suite("AudioEngine.tapInitialState — first-sound fix (PR-1)")
@MainActor
struct AudioEngineTapInitialStateTests {

    private func testPlugin() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }

    private func secondTestApp() -> AudioApp {
        AudioApp(
            id: 12346,
            processObjectIDs: [],
            name: "SecondTestApp",
            icon: NSImage(),
            bundleID: "com.test.tapinitial.second"
        )
    }

    @Test("App AU success publishes runtime, in-memory, and persisted state together")
    func appAUCommitAfterSuccessfulHandoff() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        fix.engine.addAUEffect(for: fix.app, plugin: testPlugin())

        #expect(fix.engine.getAUEffectChain(for: fix.app).count == 1)
        #expect(fix.settings.getAUEffectChain(for: fix.app.persistenceIdentifier).count == 1)
        #expect(tap.events.contains { if case .updateAUEffectChain = $0 { return true }; return false })
    }

    @Test("App AU timeout retains the old chain and persisted entries")
    func appAUTimeoutRetainsOldState() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        fix.engine.addAUEffect(for: fix.app, plugin: testPlugin())
        let oldEntries = fix.engine.getAUEffectChain(for: fix.app)
        let entryID = try #require(oldEntries.first?.id)

        tap.deferAUCompletions = true
        fix.engine.selectAUFactoryPreset(for: fix.app, entryID: entryID, presetIndex: 2)
        tap.completeNextAppAU(.rejected(reason: .timedOut))

        #expect(fix.engine.getAUEffectChain(for: fix.app) == oldEntries)
        #expect(fix.settings.getAUEffectChain(for: fix.app.persistenceIdentifier) == oldEntries)
    }

    @Test("A superseded app AU generation cannot publish over the newest request")
    func supersededAppAURequestRetainsNewestState() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        fix.engine.addAUEffect(for: fix.app, plugin: testPlugin())
        let entryID = try #require(fix.engine.getAUEffectChain(for: fix.app).first?.id)

        tap.deferAUCompletions = true
        fix.engine.selectAUFactoryPreset(for: fix.app, entryID: entryID, presetIndex: 1)
        fix.engine.selectAUFactoryPreset(for: fix.app, entryID: entryID, presetIndex: 2)
        tap.completeNextAppAU(.committed)
        #expect(fix.engine.getAUEffectChain(for: fix.app).first?.selectedFactoryPresetIndex == nil)
        tap.completeNextAppAU(.committed)

        #expect(fix.engine.getAUEffectChain(for: fix.app).first?.selectedFactoryPresetIndex == 2)
        #expect(fix.settings.getAUEffectChain(for: fix.app.persistenceIdentifier).first?.selectedFactoryPresetIndex == 2)
    }

    @Test("All matching device taps publish one successful generation")
    func deviceAUPairedSuccessPublishesAtomically() throws {
        let fix = makeFixture()
        let secondApp = secondTestApp()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        fix.engine.setDevice(for: secondApp, deviceUID: fix.device.uid)
        let taps = fix.allTaps()
        #expect(taps.count == 2)

        fix.engine.addDeviceAUEffect(deviceUID: fix.device.uid, plugin: testPlugin())

        #expect(fix.engine.getDeviceAUEffectChain(deviceUID: fix.device.uid).count == 1)
        #expect(fix.settings.getDeviceAUEffectChain(for: fix.device.uid).count == 1)
        #expect(taps.allSatisfy { tap in
            tap.events.contains { if case .updateDeviceAUEffectChain = $0 { return true }; return false }
        })
    }

    @Test("A device tap timeout rolls back successful peers without partial publication")
    func deviceAUTapTimeoutRollsBackPeers() throws {
        let fix = makeFixture()
        let secondApp = secondTestApp()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        fix.engine.setDevice(for: secondApp, deviceUID: fix.device.uid)
        let taps = fix.allTaps()
        #expect(taps.count == 2)
        fix.engine.addDeviceAUEffect(deviceUID: fix.device.uid, plugin: testPlugin())
        let oldEntries = fix.engine.getDeviceAUEffectChain(deviceUID: fix.device.uid)

        taps.forEach { $0.deferAUCompletions = true }
        fix.engine.removeDeviceAUEffect(deviceUID: fix.device.uid, entryID: try #require(oldEntries.first?.id))
        taps[0].completeNextDeviceAU(.committed)
        taps[1].completeNextDeviceAU(.rejected(reason: .timedOut))

        #expect(fix.engine.getDeviceAUEffectChain(deviceUID: fix.device.uid) == oldEntries)
        #expect(fix.settings.getDeviceAUEffectChain(for: fix.device.uid) == oldEntries)
        #expect(taps[0].events.contains { event in
            if case .updateDeviceAUEffectChain(let entries) = event { return entries == oldEntries }
            return false
        })
    }

    @Test("Failed app AU removal retains the editor's chain state")
    func failedAppAURemovalDoesNotCloseState() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        fix.engine.addAUEffect(for: fix.app, plugin: testPlugin())
        let oldEntries = fix.engine.getAUEffectChain(for: fix.app)

        tap.deferAUCompletions = true
        fix.engine.removeAUEffect(for: fix.app, entryID: try #require(oldEntries.first?.id))
        tap.completeNextAppAU(.rejected(reason: .timedOut))

        #expect(fix.engine.getAUEffectChain(for: fix.app) == oldEntries)
        #expect(fix.settings.getAUEffectChain(for: fix.app.persistenceIdentifier) == oldEntries)
    }

    @Test("Repeated handoff completion cannot commit an app AU request twice")
    func appAUCompletionIsConsumedOnce() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        fix.engine.addAUEffect(for: fix.app, plugin: testPlugin())
        let committed = fix.engine.getAUEffectChain(for: fix.app)
        tap.repeatLastAppAUCompletion(.committed)

        #expect(fix.engine.getAUEffectChain(for: fix.app) == committed)
        #expect(fix.settings.getAUEffectChain(for: fix.app.persistenceIdentifier) == committed)
    }

    // MARK: Single-knob derivation

    @Test("EQ settings persisted for this app land in TapInitialState.eqSettings")
    func eqSettingsAreCarried() throws {
        let fix = makeFixture()
        let custom = EQSettings(bandGains: [3, 0, -2, 0, 0, 0, 0, 0, 0, 4], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.eqSettings == custom)
    }

    @Test("autoEQPreampEnabled mirrors settingsManager.autoEQPreampEnabled",
          arguments: [true, false])
    func autoEQPreampEnabledMirrored(value: Bool) throws {
        let fix = makeFixture()
        fix.settings.autoEQPreampEnabled = value

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQPreampEnabled == value)
    }

    @Test("loudnessCompensationEnabled mirrors appSettings.loudnessCompensationEnabled",
          arguments: [true, false])
    func loudnessCompensationFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessCompensationEnabled == value)
    }

    @Test("loudnessEqualizerSettings.enabled mirrors appSettings.loudnessEqualizationEnabled",
          arguments: [true, false])
    func loudnessEqualizerFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessEqualizationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessEqualizerSettings.enabled == value)
    }

    @Test("loudnessVolume = currentDeviceVolume × per-app volume")
    func loudnessVolumeIsProduct() throws {
        let fix = makeFixture(deviceVolume: 0.5)
        fix.engine.volumeState.setVolume(for: fix.app.id, to: 0.4, identifier: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        // applyTapOutputState() runs before tapInitialState() is built, so
        // currentDeviceVolume is 0.5 (from MockDeviceVolumeProviding.volumes).
        // loudnessVolume should be deviceVolume (0.5) × appVolume (0.4) = 0.2.
        #expect(abs(snap.loudnessVolume - 0.2) < 1e-6)
    }

    // MARK: AutoEQ profile resolution

    @Test("autoEQProfile is nil when the device does not support AutoEQ")
    func autoEQNilForUnsupportedDevice() throws {
        let fix = makeFixture(supportsAutoEQ: false)
        // Even if a selection exists, an unsupported device must skip AutoEQ.
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when no selection is persisted for the device")
    func autoEQNilWithNoSelection() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        // Don't set any selection.

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when the selection is disabled")
    func autoEQNilWhenSelectionDisabled() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: false)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when selection is enabled but profile is not in the cache")
    func autoEQNilWhenProfileNotCached() throws {
        // Default AutoEQProfileManager has no profiles cached for "missing-id".
        // The pre-activate synchronous lookup must return nil so that
        // ensureTapExists falls through to the async resolve branch.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    // MARK: Ordering / post-activation behaviour

    @Test("activate(initial:) is the first event the controller observes")
    func activateIsFirstEvent() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let firstEvent = try #require(tap.events.first)
        if case .activate = firstEvent {
            // ok
        } else {
            Issue.record("First event was \(firstEvent), expected .activate")
        }
    }

    @Test("No EQ/AutoEQ/Loudness mutation runs BEFORE activate(initial:) — the apply-initial-state contract")
    func noMutationBeforeActivate() throws {
        // The core PR-1 invariant: every processor-state knob the audio thread
        // can observe must be set via TapInitialState, not via post-construction
        // calls that race with AudioDeviceStart. We assert this by checking
        // that no .updateEQSettings / .updateAutoEQProfile / .setAutoEQPreampEnabled
        // / .updateLoudnessCompensation / .updateLoudnessEqualization is recorded
        // BEFORE the .activate event in the tap's event log.
        //
        // Exercises a realistic config (AutoEQ-capable device with an enabled
        // selection whose profile is uncached) so applyAutoEQToTap runs
        // post-activate — proving the engine's fallback path doesn't accidentally
        // fire before activate.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )
        let custom = EQSettings(bandGains: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = true
        s.loudnessEqualizationEnabled = true
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let activateIndex = try #require(tap.events.firstIndex { event in
            if case .activate = event { return true }
            return false
        })

        for event in tap.events.prefix(activateIndex) {
            switch event {
            case .updateEQSettings, .updateAutoEQProfile, .setAutoEQPreampEnabled,
                 .updateLoudnessCompensation, .updateLoudnessEqualization:
                Issue.record("Pre-activate mutation breaks the apply-initial-state contract: \(event)")
            case .activate, .invalidate, .updateAUEffectChain, .updateDeviceAUEffectChain:
                break
            }
        }
    }

    @Test("Cache-miss AutoEQ: applyAutoEQToTap fires its sync nil-set after activate")
    func cacheMissTriggersPostActivateNilSet() throws {
        // Device supports AutoEQ + selection is enabled but profile is missing
        // from cache → ensureTapExists calls applyAutoEQToTap, which sets the
        // profile to nil synchronously before kicking off async resolution.
        // Verifies the engine's fallback path is reached when (and only when)
        // the synchronous pre-activate lookup misses.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        // The first event must still be .activate (apply-initial-state ordering)
        if case .activate = tap.events.first {
            // ok
        } else {
            Issue.record("activate(initial:) was not first event")
        }
        // A post-activate updateAutoEQProfile(nil) must be present from
        // applyAutoEQToTap's sync nil-set on cache miss.
        let postActivateAutoEQ = tap.events.dropFirst().compactMap { event -> String?? in
            if case let .updateAutoEQProfile(id) = event { return Optional(id) }
            return nil
        }
        #expect(postActivateAutoEQ.contains(where: { $0 == nil }))
    }
}

// MARK: - Helpers

@MainActor
private func capturedInitial(_ fix: Fixture) -> RecordingProcessTapController.TapInitialStateSnapshot? {
    guard let tap = fix.lastTap() else { return nil }
    for event in tap.events {
        if case let .activate(snapshot) = event { return snapshot }
    }
    return nil
}

// MARK: - Mock contract

@Suite("RecordingProcessTapController — protocol contract")
@MainActor
struct RecordingProcessTapControllerContractTests {
    @Test("Mock records activate, then mutation events, in invocation order")
    func recordsCallOrder() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        try tap.activate(initial: TapInitialState())
        tap.updateEQSettings(EQSettings.flat)
        tap.updateAutoEQProfile(nil)

        #expect(tap.events.count == 3)
        if case .activate = tap.events[0] {} else { Issue.record("expected .activate at 0") }
        if case .updateEQSettings = tap.events[1] {} else { Issue.record("expected .updateEQSettings at 1") }
        if case .updateAutoEQProfile = tap.events[2] {} else { Issue.record("expected .updateAutoEQProfile at 2") }
    }

    @Test("Default property values match real controller defaults")
    func defaultsMatchProductionController() {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        // ProcessTapController's nonisolated(unsafe) defaults from source.
        #expect(tap.volume == 1.0)
        #expect(tap.isMuted == false)
        #expect(tap.currentDeviceVolume == 1.0)
        #expect(tap.isDeviceMuted == false)
        #expect(tap.audioLevel == 0.0)
        #expect(tap.tapSourceDeviceUID == nil)
        #expect(tap.currentDeviceUID == "uid")
    }

    @Test("Backward-compatible activate() convenience routes through activate(initial:)")
    func convenienceActivateRoutesThroughInitial() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        // Convenience extension on the protocol: should funnel through activate(initial:)
        // with a default TapInitialState — proves no caller can sneak around the
        // initial-state contract by calling the old no-arg overload.
        try tap.activate()
        if case let .activate(snap) = tap.events.first {
            #expect(snap.autoEQProfileID == nil)
            #expect(snap.loudnessCompensationEnabled == false)
            #expect(snap.loudnessEqualizerSettings.enabled == false)
            #expect(snap.autoEQPreampEnabled == false)
            #expect(snap.eqSettings == EQSettings.flat)
            #expect(snap.loudnessVolume == 1.0)
        } else {
            Issue.record("activate() did not record an .activate event")
        }
    }
}
