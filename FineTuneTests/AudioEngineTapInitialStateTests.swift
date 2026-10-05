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
        var appAUEffectChain: [AUEffectChainEntry]
        var appAUBypassed: Bool
        var deviceAUEffectChain: [AUEffectChainEntry]
        var deviceAUBypassed: Bool

        @MainActor
        init(_ s: TapInitialState) {
            self.eqSettings = s.eqSettings
            self.autoEQProfileID = s.autoEQProfile?.id
            self.autoEQPreampEnabled = s.autoEQPreampEnabled
            self.loudnessVolume = s.loudnessVolume
            self.loudnessCompensationEnabled = s.loudnessCompensationEnabled
            self.loudnessEqualizerSettings = s.loudnessEqualizerSettings
            self.appAUEffectChain = s.appAUEffectChain
            self.appAUBypassed = s.appAUBypassed
            self.deviceAUEffectChain = s.deviceAUEffectChain
            self.deviceAUBypassed = s.deviceAUBypassed
        }
    }

    let app: AudioApp
    let auTransactionOwnerID = UUID()
    private(set) var events: [Event] = []
    var appAUResult: AUChainUpdateResult = .committed
    var deviceAUResult: AUChainUpdateResult = .committed
    var deferAUCompletions = false
    private(set) var pendingAppAUCompletions: [@MainActor @Sendable (AUChainUpdateResult) -> Void] = []
    private(set) var pendingDeviceAUCompletions: [@MainActor @Sendable (AUChainUpdateResult) -> Void] = []
    private(set) var pendingDevicePrepareCompletions: [@MainActor @Sendable (AUChainUpdateResult) -> Void] = []
    private(set) var devicePrepareRequestCount = 0
    private(set) var preparedDeviceEntries: [[AUEffectChainEntry]] = []
    private(set) var publishedDeviceEntries: [[AUEffectChainEntry]] = []
    private(set) var abortedDeviceTokenIDs: [UUID] = []
    var deferDevicePrepares = false
    private var deviceEntries: [AUEffectChainEntry] = []
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

    func prepareDeviceAUEffectChain(
        _ entries: [AUEffectChainEntry],
        requestGeneration: UInt64,
        completion: @escaping @MainActor @Sendable (AUChainPreparationResult) -> Void
    ) {
        devicePrepareRequestCount += 1
        preparedDeviceEntries.append(entries)
        let token = AUChainPreparedToken(
            requestGeneration: requestGeneration,
            tapIdentity: auTransactionOwnerID,
            previousEntries: deviceEntries,
            currentEntries: entries
        )
        if deferDevicePrepares {
            pendingDevicePrepareCompletions.append { result in
                switch result {
                case .committed:
                    completion(.prepared(token))
                case .rejected(let reason):
                    completion(.rejected(reason: reason))
                case .superseded:
                    completion(.superseded)
                }
            }
        } else {
            completion(.prepared(token))
        }
    }

    func claimPreparedDeviceAUEffectChain(_ token: AUChainPreparedToken, requestGeneration: UInt64) -> Bool {
        token.claimCommit(tapIdentity: auTransactionOwnerID, requestGeneration: requestGeneration)
    }

    func commitClaimedDeviceAUEffectChain(_ token: AUChainPreparedToken) {
        guard token.finishCommit() else { return }
        deviceEntries = token.currentEntries
        publishedDeviceEntries.append(token.currentEntries)
    }

    func abortPreparedDeviceAUEffectChain(_ token: AUChainPreparedToken) {
        guard token.abort() else { return }
        abortedDeviceTokenIDs.append(token.tokenID)
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

    func completeNextDevicePrepare(_ result: AUChainUpdateResult = .committed) {
        guard !pendingDevicePrepareCompletions.isEmpty else { return }
        pendingDevicePrepareCompletions.removeFirst()(result)
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

        taps.forEach { $0.deferDevicePrepares = true }
        fix.engine.addDeviceAUEffect(deviceUID: fix.device.uid, plugin: testPlugin())
        #expect(fix.engine.getDeviceAUEffectChain(deviceUID: fix.device.uid).isEmpty)
        #expect(fix.settings.getDeviceAUEffectChain(for: fix.device.uid).isEmpty)
        taps[0].completeNextDevicePrepare()
        #expect(fix.engine.getDeviceAUEffectChain(deviceUID: fix.device.uid).isEmpty)
        taps[1].completeNextDevicePrepare()

        #expect(fix.engine.getDeviceAUEffectChain(deviceUID: fix.device.uid).count == 1)
        #expect(fix.settings.getDeviceAUEffectChain(for: fix.device.uid).count == 1)
        #expect(taps.allSatisfy { $0.publishedDeviceEntries.count == 1 })
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

    @Test("Persisted app and primary-device AU state is present before activation")
    func auStateIsCarriedIntoActivation() throws {
        let fix = makeFixture()
        let appEntry = AUEffectChainEntry(plugin: testPlugin())
        let deviceEntry = AUEffectChainEntry(plugin: testPlugin())
        fix.settings.setAUEffectChain([appEntry], for: fix.app.persistenceIdentifier)
        fix.settings.setDeviceAUEffectChain([deviceEntry], for: fix.device.uid)
        fix.settings.setAppAUBypassed(true, for: fix.app.persistenceIdentifier)
        fix.settings.setDeviceAUBypassed(true, for: fix.device.uid)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let snap = try #require(capturedInitial(fix))
        #expect(snap.appAUEffectChain == [appEntry])
        #expect(snap.appAUBypassed)
        #expect(snap.deviceAUEffectChain == [deviceEntry])
        #expect(snap.deviceAUBypassed)
        #expect(!tap.events.contains { event in
            if case .updateAUEffectChain = event { return true }
            return false
        })
        #expect(!tap.events.contains { event in
            if case .updateDeviceAUEffectChain = event { return true }
            return false
        })
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

@MainActor
private func makeCoordinatorTaps() -> [RecordingProcessTapController] {
    [
        RecordingProcessTapController(
            app: AudioApp(id: 20001, processObjectIDs: [], name: "One", icon: NSImage(), bundleID: "com.test.coordinator.one"),
            deviceUIDs: ["uid-test"]
        ),
        RecordingProcessTapController(
            app: AudioApp(id: 20002, processObjectIDs: [], name: "Two", icon: NSImage(), bundleID: "com.test.coordinator.two"),
            deviceUIDs: ["uid-test"]
        )
    ]
}

@MainActor
private final class CoordinatorResultBox {
    var committed = 0
    var rejected: [AUChainUpdateResult] = []
}

@Suite("Device AU prepare/commit/abort coordinator")
@MainActor
struct DeviceAUChainTransactionCoordinatorTests {
    private func entries() -> [AUEffectChainEntry] {
        [AUEffectChainEntry(plugin: AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        ))]
    }

    private func coordinator(
        taps: [RecordingProcessTapController],
        result: CoordinatorResultBox
    ) -> DeviceAUChainTransactionCoordinator {
        let coordinator = DeviceAUChainTransactionCoordinator()
        coordinator.begin(
            deviceUID: "uid-test",
            generation: 7,
            entries: entries(),
            participants: [10001: taps[0], 10002: taps[1]],
            onCommitted: { result.committed += 1 },
            onRejected: { result.rejected.append($0) }
        )
        return coordinator
    }

    @Test("Two taps prepare and both commit one generation")
    func bothPrepareAndCommit() {
        let taps = makeCoordinatorTaps()
        let result = CoordinatorResultBox()
        _ = coordinator(taps: taps, result: result)

        #expect(result.committed == 1)
        #expect(result.rejected.isEmpty)
        #expect(taps.allSatisfy { $0.publishedDeviceEntries.count == 1 })
        #expect(taps.allSatisfy { $0.abortedDeviceTokenIDs.isEmpty })
    }

    @Test("A timeout aborts the first prepared tap without partial publication")
    func secondPrepareTimeoutAbortsAll() {
        let taps = makeCoordinatorTaps()
        taps.forEach { $0.deferDevicePrepares = true }
        let result = CoordinatorResultBox()
        let coordinator = coordinator(taps: taps, result: result)

        taps[0].completeNextDevicePrepare()
        taps[1].completeNextDevicePrepare(.rejected(reason: .timedOut))

        #expect(result.committed == 0)
        #expect(result.rejected == [.rejected(reason: .timedOut)])
        #expect(taps.allSatisfy { $0.publishedDeviceEntries.isEmpty })
        #expect(taps[0].abortedDeviceTokenIDs.count == 1)
    }

    @Test("A superseded prepare aborts every prepared token")
    func supersededPrepareAbortsAll() {
        let taps = makeCoordinatorTaps()
        taps.forEach { $0.deferDevicePrepares = true }
        let result = CoordinatorResultBox()
        let coordinator = coordinator(taps: taps, result: result)

        taps[0].completeNextDevicePrepare()
        coordinator.cancel(deviceUID: "uid-test")
        taps[1].completeNextDevicePrepare()

        #expect(result.committed == 0)
        #expect(result.rejected == [.superseded])
        #expect(taps.allSatisfy { $0.publishedDeviceEntries.isEmpty })
        #expect(taps.allSatisfy { $0.abortedDeviceTokenIDs.count == 1 })
    }

    @Test("A disappearing tap aborts prepared and late tokens")
    func disappearingTapAbortsAll() {
        let taps = makeCoordinatorTaps()
        taps.forEach { $0.deferDevicePrepares = true }
        let result = CoordinatorResultBox()
        let coordinator = coordinator(taps: taps, result: result)

        taps[0].completeNextDevicePrepare()
        coordinator.tapDidDisappear(taps[0])
        taps[1].completeNextDevicePrepare()

        #expect(result.committed == 0)
        #expect(result.rejected == [.superseded])
        #expect(taps.allSatisfy { $0.publishedDeviceEntries.isEmpty })
        #expect(taps.allSatisfy { $0.abortedDeviceTokenIDs.count == 1 })
    }

    @Test("Stale token cannot commit")
    func staleTokenCannotCommit() {
        let tap = makeCoordinatorTaps()[0]
        let token = AUChainPreparedToken(
            requestGeneration: 7,
            tapIdentity: tap.auTransactionOwnerID,
            previousEntries: [],
            currentEntries: entries()
        )

        #expect(!tap.claimPreparedDeviceAUEffectChain(token, requestGeneration: 8))
        tap.abortPreparedDeviceAUEffectChain(token)
        #expect(token.lifecycle == .aborted)
        #expect(!token.claimCommit(tapIdentity: tap.auTransactionOwnerID, requestGeneration: 7))
    }

    @Test("Token commit and abort are each consumed exactly once")
    func tokenConsumptionIsOneShot() {
        let tap = makeCoordinatorTaps()[0]
        let commitToken = AUChainPreparedToken(
            requestGeneration: 1,
            tapIdentity: tap.auTransactionOwnerID,
            previousEntries: [],
            currentEntries: entries()
        )
        #expect(commitToken.claimCommit(tapIdentity: tap.auTransactionOwnerID, requestGeneration: 1))
        #expect(commitToken.finishCommit())
        #expect(!commitToken.finishCommit())
        #expect(!commitToken.abort())

        let abortToken = AUChainPreparedToken(
            requestGeneration: 1,
            tapIdentity: tap.auTransactionOwnerID,
            previousEntries: [],
            currentEntries: entries()
        )
        #expect(abortToken.abort())
        #expect(!abortToken.abort())
    }

    @Test("A tap enrolled during prepare joins before commit")
    func enrollmentWaitsForNewTap() {
        let taps = makeCoordinatorTaps()
        taps[0].deferDevicePrepares = true
        taps[1].deferDevicePrepares = true
        let result = CoordinatorResultBox()
        let coordinator = DeviceAUChainTransactionCoordinator()
        coordinator.begin(
            deviceUID: "uid-test",
            generation: 8,
            entries: entries(),
            participants: [10001: taps[0]],
            onCommitted: { result.committed += 1 },
            onRejected: { result.rejected.append($0) }
        )

        #expect(coordinator.enroll(taps[1], pid: 10002, forDeviceUID: "uid-test"))
        taps[0].completeNextDevicePrepare()
        #expect(result.committed == 0)
        taps[1].completeNextDevicePrepare()

        #expect(result.committed == 1)
        #expect(taps.allSatisfy { $0.publishedDeviceEntries.count == 1 })
        #expect(taps[0].preparedDeviceEntries == taps[1].preparedDeviceEntries)
    }

    @Test("A newly enrolled timeout aborts all prepared tokens")
    func enrolledTimeoutAbortsAll() {
        let taps = makeCoordinatorTaps()
        taps[0].deferDevicePrepares = true
        taps[1].deferDevicePrepares = true
        let result = CoordinatorResultBox()
        let coordinator = DeviceAUChainTransactionCoordinator()
        coordinator.begin(
            deviceUID: "uid-test",
            generation: 8,
            entries: entries(),
            participants: [10001: taps[0]],
            onCommitted: { result.committed += 1 },
            onRejected: { result.rejected.append($0) }
        )
        #expect(coordinator.enroll(taps[1], pid: 10002, forDeviceUID: "uid-test"))

        taps[0].completeNextDevicePrepare()
        taps[1].completeNextDevicePrepare(.rejected(reason: .timedOut))

        #expect(result.committed == 0)
        #expect(result.rejected == [.rejected(reason: .timedOut)])
        #expect(taps.allSatisfy { $0.publishedDeviceEntries.isEmpty })
        #expect(taps[0].abortedDeviceTokenIDs.count == 1)
    }

    @Test("A disappearing enrolled tap aborts the transaction")
    func enrolledDisappearanceAbortsAll() {
        let taps = makeCoordinatorTaps()
        taps[0].deferDevicePrepares = true
        taps[1].deferDevicePrepares = true
        let result = CoordinatorResultBox()
        let coordinator = DeviceAUChainTransactionCoordinator()
        coordinator.begin(
            deviceUID: "uid-test",
            generation: 8,
            entries: entries(),
            participants: [10001: taps[0]],
            onCommitted: { result.committed += 1 },
            onRejected: { result.rejected.append($0) }
        )
        #expect(coordinator.enroll(taps[1], pid: 10002, forDeviceUID: "uid-test"))
        taps[0].completeNextDevicePrepare()
        coordinator.tapDidDisappear(taps[1])

        #expect(result.committed == 0)
        #expect(result.rejected == [.superseded])
        #expect(taps.allSatisfy { $0.publishedDeviceEntries.isEmpty })
        #expect(taps[0].abortedDeviceTokenIDs.count == 1)
    }

    @Test("A tap cannot be enrolled twice or for another device")
    func enrollmentIdentityAndDeviceGuards() {
        let taps = makeCoordinatorTaps()
        taps[0].deferDevicePrepares = true
        let coordinator = DeviceAUChainTransactionCoordinator()
        coordinator.begin(
            deviceUID: "uid-test",
            generation: 8,
            entries: entries(),
            participants: [10001: taps[0]],
            onCommitted: {},
            onRejected: { _ in }
        )

        #expect(!coordinator.enroll(taps[0], pid: 10001, forDeviceUID: "uid-test"))
        #expect(!coordinator.enroll(taps[1], pid: 10002, forDeviceUID: "other-device"))
        #expect(coordinator.enroll(taps[1], pid: 10002, forDeviceUID: "uid-test"))
        #expect(!coordinator.enroll(taps[1], pid: 10002, forDeviceUID: "uid-test"))
        #expect(taps[1].devicePrepareRequestCount == 1)
    }

    @Test("Enrollment is refused after synchronous commit")
    func enrollmentRefusedAfterCommit() {
        let taps = makeCoordinatorTaps()
        let result = CoordinatorResultBox()
        let coordinator = DeviceAUChainTransactionCoordinator()
        coordinator.begin(
            deviceUID: "uid-test",
            generation: 8,
            entries: entries(),
            participants: [10001: taps[0]],
            onCommitted: { result.committed += 1 },
            onRejected: { result.rejected.append($0) }
        )

        #expect(result.committed == 1)
        #expect(!coordinator.enroll(taps[1], pid: 10002, forDeviceUID: "uid-test"))
        #expect(taps[1].devicePrepareRequestCount == 0)
    }
}

@Suite("AudioEngine device AU enrollment")
@MainActor
struct AudioEngineDeviceAUEnrollmentTests {
    @Test("A tap created during prepare is enrolled and commits with its peers")
    func newTapJoinsPendingDeviceTransaction() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let firstTap = try #require(fix.lastTap())
        firstTap.deferDevicePrepares = true
        fix.engine.addDeviceAUEffect(deviceUID: fix.device.uid, plugin: enrollmentTestPlugin())

        let newApp = AudioApp(
            id: 12347,
            processObjectIDs: [],
            name: "EnrolledApp",
            icon: NSImage(),
            bundleID: "com.test.tapinitial.enrolled"
        )
        fix.engine.setDevice(for: newApp, deviceUID: fix.device.uid)
        let secondTap = try #require(fix.allTaps().last)
        #expect(secondTap.devicePrepareRequestCount == 1)
        #expect(fix.engine.getDeviceAUEffectChain(deviceUID: fix.device.uid).isEmpty)

        firstTap.completeNextDevicePrepare()

        #expect(fix.engine.getDeviceAUEffectChain(deviceUID: fix.device.uid).count == 1)
        #expect(fix.settings.getDeviceAUEffectChain(for: fix.device.uid).count == 1)
        #expect(firstTap.publishedDeviceEntries.count == 1)
        #expect(secondTap.publishedDeviceEntries.count == 1)

        let postCommitApp = AudioApp(
            id: 12348,
            processObjectIDs: [],
            name: "PostCommitApp",
            icon: NSImage(),
            bundleID: "com.test.tapinitial.postcommit"
        )
        fix.engine.setDevice(for: postCommitApp, deviceUID: fix.device.uid)
        let postCommitTap = try #require(fix.allTaps().last)
        #expect(postCommitTap.devicePrepareRequestCount == 0)
        let postCommitInitial = postCommitTap.events.compactMap { event -> RecordingProcessTapController.TapInitialStateSnapshot? in
            if case let .activate(snapshot) = event { return snapshot }
            return nil
        }.first
        #expect(postCommitInitial?.deviceAUEffectChain.count == 1)
        #expect(!postCommitTap.events.contains { event in
            if case .updateDeviceAUEffectChain = event { return true }
            return false
        })
    }

    private func enrollmentTestPlugin() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
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
