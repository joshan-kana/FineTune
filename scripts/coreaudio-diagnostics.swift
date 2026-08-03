import CoreAudio
import Foundation

func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    let storage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
    defer { storage.deallocate() }
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)
    var size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr else { return nil }
    return storage.load(as: T.self)
}

func stringValue(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var result: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
    return result?.takeUnretainedValue() as String?
}

var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var devicesSize: UInt32 = 0
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &devicesSize) == noErr else { exit(1) }
var devices = [AudioDeviceID](repeating: 0, count: Int(devicesSize) / MemoryLayout<AudioDeviceID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &devicesSize, &devices) == noErr else { exit(1) }
let defaultOutput: AudioDeviceID? = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)

for device in devices {
    guard let name = stringValue(device, kAudioObjectPropertyName) else { continue }
    let rate: Float64 = value(device, kAudioDevicePropertyNominalSampleRate) ?? 0
    let frames: UInt32 = value(device, kAudioDevicePropertyBufferFrameSize) ?? 0
    let latency: UInt32 = value(device, kAudioDevicePropertyLatency, scope: kAudioDevicePropertyScopeOutput) ?? 0
    let safety: UInt32 = value(device, kAudioDevicePropertySafetyOffset, scope: kAudioDevicePropertyScopeOutput) ?? 0
    let milliseconds = rate > 0 ? Double(frames + latency + safety) / rate * 1_000 : 0
    let marker = device == defaultOutput ? "default" : "available"
    print("\(name) [\(marker)]: \(Int(rate)) Hz, buffer \(frames) frames, device latency \(latency), safety \(safety), one-way floor \(String(format: "%.2f", milliseconds)) ms")
}
