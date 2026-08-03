import CoreAudio
import Foundation

let targetName = "FineTune DSP Bus"
var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { exit(1) }
let count = Int(size) / MemoryLayout<AudioDeviceID>.size
var devices = [AudioDeviceID](repeating: 0, count: count)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { exit(1) }

for device in devices {
    var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr else { continue }
    guard let value = name?.takeRetainedValue() as String?, value == targetName else { continue }
    let status = AudioHardwareDestroyAggregateDevice(device)
    guard status == noErr else { fputs("failed to remove exact aggregate: \(status)\n", stderr); exit(1) }
    print("removed exact aggregate: \(targetName)")
    exit(0)
}
print("exact aggregate not found: \(targetName)")
