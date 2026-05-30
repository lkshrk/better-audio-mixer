// Step-2a gate: prove the BAM custom claim properties round-trip through the driver.
// Sets kBAMClaimed / kBAMMixName / kBAMChannels on the BAM device, reads them back.
//
// Build: swiftc -O claimcheck.swift -o claimcheck -framework CoreAudio -framework Foundation
// Run:   ./claimcheck            (BAM.driver must be installed/reloaded)
import CoreAudio
import Foundation

let targetUID = "BAM_UID"

func fourCC(_ s: String) -> AudioObjectPropertySelector {
    var r: UInt32 = 0
    for b in s.utf8 { r = (r << 8) | UInt32(b) }
    return r
}
let kClaimed = fourCC("bmcl")
let kMixName = fourCC("bmnm")
let kChannels = fourCC("bmch")

func findDevice(uid: String) -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
    let n = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: n)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
    for id in ids {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cf) == noErr, (cf?.takeRetainedValue() as String?) == uid { return id }
    }
    return nil
}

func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

// Claimed/Channels are custom CFPropertyList properties carrying a CFNumber (UInt32).
func setU32(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: UInt32) -> OSStatus {
    var a = addr(sel); var val = v
    var cf = CFNumberCreate(nil, .sInt32Type, &val)
    return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<CFTypeRef>.size), &cf)
}
func getU32(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
    var a = addr(sel); var cf: Unmanaged<CFNumber>?; var s = UInt32(MemoryLayout<CFTypeRef>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &cf) == noErr, let num = cf?.takeRetainedValue() else { return nil }
    var out: UInt32 = 0
    return CFNumberGetValue(num, .sInt32Type, &out) ? out : nil
}
func setStr(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: String) -> OSStatus {
    var a = addr(sel); var cf = v as CFString
    return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<CFString>.size), &cf)
}
func getStr(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel); var cf: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &cf) == noErr ? (cf?.takeRetainedValue() as String?) : nil
}

guard let dev = findDevice(uid: targetUID) else {
    FileHandle.standardError.write("FAIL: BAM device not found. Install/reload driver.\n".data(using: .utf8)!)
    exit(2)
}
print("Found BAM device id=\(dev)")

let s1 = setU32(dev, kClaimed, 1)
let s2 = setStr(dev, kMixName, "Stream")
let s3 = setU32(dev, kChannels, 2)
print("set claimed=\(s1) name=\(s2) channels=\(s3)")

let gc = getU32(dev, kClaimed)
let gn = getStr(dev, kMixName)
let gch = getU32(dev, kChannels)
print("readback claimed=\(gc.map(String.init) ?? "nil") name=\(gn ?? "nil") channels=\(gch.map(String.init) ?? "nil")")

if s1 == noErr, s2 == noErr, s3 == noErr, gc == 1, gn == "Stream", gch == 2 {
    print("PASS: BAM claim contract round-trips through the driver.")
    exit(0)
} else {
    print("FAIL: claim properties did not round-trip.")
    exit(1)
}
