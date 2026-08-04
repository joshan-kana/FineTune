/// Abstraction over process tap controllers for testability.
///
/// **Threading:** The protocol surface is `@MainActor` — AudioEngine and tests
/// interact with controllers from main. The concrete class straddles main and the
/// CoreAudio HAL I/O thread, but the audio callback never goes through this
/// protocol; it reads `nonisolated(unsafe)` atomic fields directly on the concrete
/// type via a `void *` userdata pointer.
import Foundation

@MainActor
enum AUChainUpdateRejection: Equatable, Sendable {
    case timedOut
}

@MainActor
enum AUChainUpdateResult: Equatable, Sendable {
    case committed
    case rejected(reason: AUChainUpdateRejection)
    case superseded
}

@MainActor
enum AUChainPreparationResult: Sendable {
    case prepared(AUChainPreparedToken)
    case rejected(reason: AUChainUpdateRejection)
    case superseded
}

/// A prepared AU replacement is inert until its owner claims and commits it.
/// The coordinator can therefore abort prepared replacements without publishing
/// a temporary generation or sending a compensating runtime update.
@MainActor
class AUChainPreparedToken: @unchecked Sendable {
    enum Lifecycle {
        case prepared
        case commitClaimed
        case committed
        case aborted
    }

    let tokenID: UUID
    let requestGeneration: UInt64
    let tapIdentity: UUID
    let previousEntries: [AUEffectChainEntry]
    let currentEntries: [AUEffectChainEntry]
    let expiresAt: Date
    private(set) var lifecycle: Lifecycle = .prepared

    init(
        tokenID: UUID = UUID(),
        requestGeneration: UInt64,
        tapIdentity: UUID,
        previousEntries: [AUEffectChainEntry],
        currentEntries: [AUEffectChainEntry],
        expiresAt: Date = Date().addingTimeInterval(1)
    ) {
        self.tokenID = tokenID
        self.requestGeneration = requestGeneration
        self.tapIdentity = tapIdentity
        self.previousEntries = previousEntries
        self.currentEntries = currentEntries
        self.expiresAt = expiresAt
    }

    func claimCommit(tapIdentity: UUID, requestGeneration: UInt64, now: Date = Date()) -> Bool {
        guard lifecycle == .prepared,
              self.tapIdentity == tapIdentity,
              self.requestGeneration == requestGeneration,
              now < expiresAt else { return false }
        lifecycle = .commitClaimed
        return true
    }

    @discardableResult
    func finishCommit() -> Bool {
        guard lifecycle == .commitClaimed else { return false }
        lifecycle = .committed
        return true
    }

    @discardableResult
    func abort() -> Bool {
        guard lifecycle != .committed, lifecycle != .aborted else { return false }
        lifecycle = .aborted
        return true
    }
}

@MainActor
protocol ProcessTapControlling: AnyObject, Sendable {
    var app: AudioApp { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var currentDeviceVolume: Float { get set }
    var isDeviceMuted: Bool { get set }
    var audioLevel: Float { get }
    var currentDeviceUID: String? { get }
    var currentDeviceUIDs: [String] { get }

    func activate(initial: TapInitialState) throws
    func invalidate()
    func invalidateAsync() async
    func updateEQSettings(_ settings: EQSettings)
    func updateAutoEQProfile(_ profile: AutoEQProfile?)
    func setAutoEQPreampEnabled(_ enabled: Bool)
    func updateLoudnessCompensation(volume: Float, enabled: Bool)
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings)
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func hasRecentAudioCallback(within seconds: Double) -> Bool
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool

    var tapSourceDeviceUID: String? { get }
    var auTransactionOwnerID: UUID { get }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws
    func recreateForOutputRateChange() async throws

    func updateAUEffectChain(_ entries: [AUEffectChainEntry])
    func updateAUEffectChain(
        _ entries: [AUEffectChainEntry],
        completion: @escaping @MainActor @Sendable (AUChainUpdateResult) -> Void
    )
    func getAUEffectChainEntries() -> [AUEffectChainEntry]
    func setAUChainBypassed(_ bypassed: Bool)
    var isAUChainBypassed: Bool { get }
    func updateDeviceAUEffectChain(_ entries: [AUEffectChainEntry])
    func updateDeviceAUEffectChain(
        _ entries: [AUEffectChainEntry],
        completion: @escaping @MainActor @Sendable (AUChainUpdateResult) -> Void
    )
    func prepareDeviceAUEffectChain(
        _ entries: [AUEffectChainEntry],
        requestGeneration: UInt64,
        completion: @escaping @MainActor @Sendable (AUChainPreparationResult) -> Void
    )
    func claimPreparedDeviceAUEffectChain(_ token: AUChainPreparedToken, requestGeneration: UInt64) -> Bool
    func commitClaimedDeviceAUEffectChain(_ token: AUChainPreparedToken)
    func abortPreparedDeviceAUEffectChain(_ token: AUChainPreparedToken)
    func getDeviceAUEffectChainEntries() -> [AUEffectChainEntry]
    func setDeviceAUChainBypassed(_ bypassed: Bool)
    var isDeviceAUChainBypassed: Bool { get }
}

extension ProcessTapControlling {
    /// Convenience activation with default state. Production callers must pass an
    /// `initial:` populated from persisted settings — defaults leave the first audio
    /// callbacks running with no EQ/AutoEQ/Loudness and unity volume ramp.
    func activate() throws {
        try activate(initial: TapInitialState())
    }

    /// Convenience: defaults sourceDeviceDead to false.
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?) async throws {
        try await switchDevice(to: newDeviceUID, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: false)
    }

    /// Convenience: defaults sourceDeviceDead to false.
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?) async throws {
        try await updateDevices(to: newDeviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: false)
    }

    func invalidateAsync() async {
        invalidate()
    }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        // Default no-op for mocks that don't override
    }

    func recreateForOutputRateChange() async throws {
        // Default no-op for mocks that don't override
    }

    func updateAUEffectChain(_ entries: [AUEffectChainEntry]) {}
    func updateAUEffectChain(
        _ entries: [AUEffectChainEntry],
        completion: @escaping @MainActor @Sendable (AUChainUpdateResult) -> Void
    ) {
        updateAUEffectChain(entries)
        completion(.committed)
    }
    func getAUEffectChainEntries() -> [AUEffectChainEntry] { [] }
    func setAUChainBypassed(_ bypassed: Bool) {}
    var isAUChainBypassed: Bool { false }
    func updateDeviceAUEffectChain(_ entries: [AUEffectChainEntry]) {}
    func updateDeviceAUEffectChain(
        _ entries: [AUEffectChainEntry],
        completion: @escaping @MainActor @Sendable (AUChainUpdateResult) -> Void
    ) {
        updateDeviceAUEffectChain(entries)
        completion(.committed)
    }
    func prepareDeviceAUEffectChain(
        _ entries: [AUEffectChainEntry],
        requestGeneration: UInt64,
        completion: @escaping @MainActor @Sendable (AUChainPreparationResult) -> Void
    ) {
        let token = AUChainPreparedToken(
            requestGeneration: requestGeneration,
            tapIdentity: auTransactionOwnerID,
            previousEntries: getDeviceAUEffectChainEntries(),
            currentEntries: entries
        )
        completion(.prepared(token))
    }
    func claimPreparedDeviceAUEffectChain(_ token: AUChainPreparedToken, requestGeneration: UInt64) -> Bool {
        token.claimCommit(tapIdentity: auTransactionOwnerID, requestGeneration: requestGeneration)
    }
    func commitClaimedDeviceAUEffectChain(_ token: AUChainPreparedToken) {
        _ = token.finishCommit()
    }
    func abortPreparedDeviceAUEffectChain(_ token: AUChainPreparedToken) {
        _ = token.abort()
    }
    func getDeviceAUEffectChainEntries() -> [AUEffectChainEntry] { [] }
    func setDeviceAUChainBypassed(_ bypassed: Bool) {}
    var isDeviceAUChainBypassed: Bool { false }
}
