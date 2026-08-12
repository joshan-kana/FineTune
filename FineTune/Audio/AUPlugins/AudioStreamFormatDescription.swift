import AudioToolbox
import Foundation

/// Semantic channel roles used by the audio and Audio Unit hosts.
///
/// The order is significant: Audio Unit 5.1/7.1 layouts use the order
/// L, R, C, LFE, Ls, Rs[, Lrs, Rrs].  Keeping the roles beside the channel
/// count prevents a channel-count-only assumption from silently reordering
/// home-theatre audio.
enum AudioChannelRole: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case centre
    case lfe
    case leftSurround
    case rightSurround
    case leftRearSurround
    case rightRearSurround
    case mono
    case unknown

    var displayLabel: String {
        switch self {
        case .left: return "Front Left"
        case .right: return "Front Right"
        case .centre: return "Centre"
        case .lfe: return "LFE"
        case .leftSurround: return "Side Left"
        case .rightSurround: return "Side Right"
        case .leftRearSurround: return "Rear Left"
        case .rightRearSurround: return "Rear Right"
        case .mono: return "Mono"
        case .unknown: return "Unknown channel"
        }
    }
}

/// A user-selectable horizontal stereo pair.  The value is semantic on
/// purpose: indices are resolved from the current stream layout and are never
/// persisted as if they were stable channel identities.
enum AUStereoPair: String, Codable, CaseIterable, Sendable {
    case front
    case side
    case rear

    var label: String {
        switch self {
        case .front: return "Front L/R"
        case .side: return "Side L/R"
        case .rear: return "Rear L/R"
        }
    }

    var roles: (left: AudioChannelRole, right: AudioChannelRole) {
        switch self {
        case .front: return (.left, .right)
        case .side: return (.leftSurround, .rightSurround)
        case .rear: return (.leftRearSurround, .rightRearSurround)
        }
    }
}

enum AUProcessingMode: String, Codable, CaseIterable, Sendable {
    case auto
    case nativeMultichannel
    case independentPerChannel
    case stereoOnly
    case singleStereoPair
    case linkedStereoPairs
    case bypassForLayout

    static let userSelectableModes: [AUProcessingMode] = [
        .auto, .nativeMultichannel, .singleStereoPair, .linkedStereoPairs,
        .independentPerChannel, .bypassForLayout
    ]

    var displayLabel: String {
        switch self {
        case .auto: return "Auto"
        case .nativeMultichannel: return "Native layout"
        case .singleStereoPair: return "Single stereo pair"
        case .linkedStereoPairs: return "Linked stereo pairs"
        case .independentPerChannel: return "Independent mono"
        case .stereoOnly: return "Stereo only"
        case .bypassForLayout: return "Bypass on multichannel"
        }
    }
}

enum AUChannelSelection: String, Codable, CaseIterable, Sendable {
    case allChannels
    case allExceptLFE
    case lfeOnly
    case frontLeftRight
    case centre
    case surrounds
    case rears
    case custom
}

/// Implements the channel-count rules documented for AUChannelInfo.
///
/// -1 and -2 mean an unconstrained count, but they differ when paired:
/// {-1, -1} requires matching counts while {-1, -2} and {-2, -1} do not.
/// Values less than -2 are upper bounds across the scope's buses. Zero means
/// that the corresponding side has no elements.
enum AUChannelCapabilityMatcher {
    static func matches(input: Int, output: Int, requestedInput: Int, requestedOutput: Int) -> Bool {
        guard requestedInput >= 0, requestedOutput >= 0 else { return false }
        if input == -1, output == -1, requestedInput != requestedOutput { return false }
        return matches(count: input, requested: requestedInput) &&
            matches(count: output, requested: requestedOutput)
    }

    static func matches(count: Int, requested: Int) -> Bool {
        switch count {
        case -1, -2:
            return true
        case ...(-3):
            return requested <= abs(count)
        default:
            return count == requested
        }
    }
}

/// Immutable description of one audio render format.
///
/// This is deliberately independent of an `AudioBufferList`; a buffer list is
/// transient callback memory while this value describes the negotiated stream.
struct AudioStreamFormatDescription: Equatable, Sendable {
    let sampleRate: Double
    let frameCapacity: UInt32
    let channelCount: Int
    let isInterleaved: Bool
    let channelLayoutTag: AudioChannelLayoutTag
    let channelRoles: [AudioChannelRole]
    let inputBusCount: Int
    let outputBusCount: Int
    let bufferCount: Int
    let channelsPerBuffer: [Int]

    init(
        sampleRate: Double,
        frameCapacity: UInt32 = 4096,
        channelCount: Int,
        isInterleaved: Bool,
        channelLayoutTag: AudioChannelLayoutTag? = nil,
        channelRoles: [AudioChannelRole]? = nil,
        inputBusCount: Int = 1,
        outputBusCount: Int = 1,
        bufferCount: Int? = nil,
        channelsPerBuffer: [Int]? = nil
    ) {
        let safeChannels = max(1, channelCount)
        self.sampleRate = sampleRate
        self.frameCapacity = max(1, frameCapacity)
        self.channelCount = safeChannels
        self.isInterleaved = isInterleaved
        self.channelLayoutTag = channelLayoutTag ?? Self.defaultLayoutTag(for: safeChannels)
        self.channelRoles = channelRoles ?? Self.defaultRoles(for: safeChannels)
        self.inputBusCount = max(1, inputBusCount)
        self.outputBusCount = max(1, outputBusCount)
        self.bufferCount = max(1, bufferCount ?? (isInterleaved ? 1 : safeChannels))
        self.channelsPerBuffer = channelsPerBuffer ?? (isInterleaved ? [safeChannels] : Array(repeating: 1, count: safeChannels))
    }

    init(streamDescription: AudioStreamBasicDescription, frameCapacity: UInt32 = 4096, channelLayoutTag: AudioChannelLayoutTag? = nil) {
        self.init(
            sampleRate: streamDescription.mSampleRate,
            frameCapacity: frameCapacity,
            channelCount: Int(streamDescription.mChannelsPerFrame),
            isInterleaved: (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
            channelLayoutTag: channelLayoutTag,
            bufferCount: (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 ? 1 : Int(streamDescription.mChannelsPerFrame),
            channelsPerBuffer: (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 ? [Int(streamDescription.mChannelsPerFrame)] : Array(repeating: 1, count: Int(streamDescription.mChannelsPerFrame))
        )
    }

    var audioStreamBasicDescription: AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        let bytesPerFrame = bytesPerSample * UInt32(isInterleaved ? channelCount : 1)
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if !isInterleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    var isMultichannel: Bool { channelCount > 2 }

    /// Resolves a semantic pair against this exact stream layout. Unknown
    /// and duplicate roles are rejected; discrete channels are not guessed.
    func stereoPairChannelIndices(for pair: AUStereoPair) -> (left: Int, right: Int)? {
        let roles = pair.roles
        guard channelRoles.count == channelCount,
              let left = channelRoles.firstIndex(of: roles.left),
              let right = channelRoles.firstIndex(of: roles.right),
              left != right,
              channelRoles.filter({ $0 == roles.left }).count == 1,
              channelRoles.filter({ $0 == roles.right }).count == 1 else { return nil }
        return (left, right)
    }

    var availableStereoPairs: [AUStereoPair] {
        AUStereoPair.allCases.filter { stereoPairChannelIndices(for: $0) != nil }
    }

    var linkedStereoPairChannelIndices: [(pair: AUStereoPair, indices: (left: Int, right: Int))] {
        availableStereoPairs.compactMap { pair in
            guard let indices = stereoPairChannelIndices(for: pair) else { return nil }
            return (pair, indices)
        }
    }

    /// Backwards-compatible front-pair helper used by the original Phase A
    /// implementation.
    var frontStereoChannelIndices: (left: Int, right: Int)? {
        stereoPairChannelIndices(for: .front)
    }

    var shortLabel: String {
        switch channelCount {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "(channelCount)-channel"
        }
    }

    func audioUnitLayout() -> AudioChannelLayout? {
        guard channelLayoutTag != 0 else { return nil }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channelLayoutTag
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        layout.mNumberChannelDescriptions = 0
        return layout
    }

    static func from(bufferList: UnsafeMutableAudioBufferListPointer, sampleRate: Double, frameCapacity: UInt32 = 4096) -> AudioStreamFormatDescription {
        let channels = bufferList.reduce(0) { $0 + max(1, Int($1.mNumberChannels)) }
        let channelCounts = bufferList.map { max(1, Int($0.mNumberChannels)) }
        let interleaved = bufferList.count == 1 && channels > 1
        return AudioStreamFormatDescription(
            sampleRate: sampleRate,
            frameCapacity: frameCapacity,
            channelCount: channels,
            isInterleaved: interleaved,
            channelLayoutTag: defaultLayoutTag(for: channels),
            bufferCount: bufferList.count,
            channelsPerBuffer: channelCounts
        )
    }

    private static func defaultLayoutTag(for channels: Int) -> AudioChannelLayoutTag {
        switch channels {
        case 1: return kAudioChannelLayoutTag_Mono
        case 2: return kAudioChannelLayoutTag_Stereo
        case 6: return kAudioChannelLayoutTag_AudioUnit_5_1
        case 8: return kAudioChannelLayoutTag_AudioUnit_7_1
        default: return 0 // A valid custom layout must be supplied by the caller.
        }
    }

    private static func defaultRoles(for channels: Int) -> [AudioChannelRole] {
        switch channels {
        case 1: return [.mono]
        case 2: return [.left, .right]
        case 6: return [.left, .right, .centre, .lfe, .leftSurround, .rightSurround]
        case 8: return [.left, .right, .centre, .lfe, .leftSurround, .rightSurround, .leftRearSurround, .rightRearSurround]
        default: return Array(repeating: .unknown, count: max(1, channels))
        }
    }
}

/// Allocation-free metadata view over a callback buffer list.
struct AudioBufferListFormatView {
    let bufferCount: Int
    let channelCount: Int
    let isInterleaved: Bool
    let frameCount: Int

    init(_ buffers: UnsafeMutableAudioBufferListPointer) {
        self.bufferCount = buffers.count
        var channels = 0
        var frames = Int.max
        for buffer in buffers {
            let bufferChannels = max(1, Int(buffer.mNumberChannels))
            channels += bufferChannels
            frames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / bufferChannels)
        }
        self.channelCount = channels
        self.isInterleaved = buffers.count == 1 && channelCount > 1
        self.frameCount = frames == Int.max ? 0 : max(0, frames)
    }
}
