import AudioToolbox
import Testing
@testable import FineTune

@Suite("Multichannel audio format descriptions")
struct MultichannelAudioFormatTests {
    @Test("Audio Unit 5.1 roles preserve the documented order")
    func fiveOneOrder() {
        let format = AudioStreamFormatDescription(sampleRate: 48_000, channelCount: 6, isInterleaved: true)
        #expect(format.channelLayoutTag == kAudioChannelLayoutTag_AudioUnit_5_1)
        #expect(format.channelRoles == [.left, .right, .centre, .lfe, .leftSurround, .rightSurround])
        #expect(format.shortLabel == "5.1")
    }

    @Test("Audio Unit 7.1 roles preserve the documented order")
    func sevenOneOrder() {
        let format = AudioStreamFormatDescription(sampleRate: 96_000, channelCount: 8, isInterleaved: false)
        #expect(format.channelLayoutTag == kAudioChannelLayoutTag_AudioUnit_7_1)
        #expect(format.channelRoles == [.left, .right, .centre, .lfe, .leftSurround, .rightSurround, .leftRearSurround, .rightRearSurround])
        #expect(format.channelsPerBuffer == Array(repeating: 1, count: 8))
    }

    @Test("ASBD reflects interleaving and channel count")
    func streamDescription() {
        let interleaved = AudioStreamFormatDescription(sampleRate: 44_100, channelCount: 6, isInterleaved: true)
        let planar = AudioStreamFormatDescription(sampleRate: 44_100, channelCount: 6, isInterleaved: false)
        #expect(interleaved.audioStreamBasicDescription.mBytesPerFrame == 24)
        #expect(planar.audioStreamBasicDescription.mBytesPerFrame == 4)
        #expect((planar.audioStreamBasicDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0)
    }

    @Test("Processing modes and channel selections are persisted")
    func modePersistence() throws {
        var entry = AUEffectChainEntry(plugin: AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 1,
            componentManufacturer: 2,
            name: "Test",
            manufacturer: "Test",
            version: 1
        ))
        entry.processingMode = .independentPerChannel
        entry.channelSelection = .allExceptLFE
        let roundTrip = try JSONDecoder().decode(AUEffectChainEntry.self, from: JSONEncoder().encode(entry))
        #expect(roundTrip.processingMode == .independentPerChannel)
        #expect(roundTrip.channelSelection == .allExceptLFE)
    }
}
