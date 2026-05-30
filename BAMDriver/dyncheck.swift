// Step-2b dynamic-publication spike: prove the driver can add/remove a device at runtime
// (no coreaudiod reload) by toggling its box's kAudioBoxPropertyAcquired and watching the
// global device list. If BAM_UID disappears when unacquired and reappears when re-acquired,
// the dynamic device-list primitive (host re-queries kAudioPlugInPropertyDeviceList on
// PropertiesChanged) works — the foundation for per-mix dynamic publication.
//
// Build: swiftc -O dyncheck.swift -o dyncheck -framework CoreAudio -framework Foundation
// Run:   ./dyncheck            (BAM.driver installed)
import CoreAudio
import Foundation

let boxUID = "BAM_UID"
let deviceUID = "BAM_UID"

func sysAddr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func objectList(_ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = sysAddr(sel); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    let n = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: n)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func uidOf(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = sysAddr(sel); var cf: Unmanaged<CFString>?
    var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cf) == noErr ? (cf?.takeRetainedValue() as String?) : nil
}

func bamDevicePresent() -> Bool {
    objectList(kAudioHardwarePropertyDevices).contains { uidOf($0, kAudioDevicePropertyDeviceUID) == deviceUID }
}

func findBox() -> AudioObjectID? {
    objectList(kAudioHardwarePropertyBoxList).first { uidOf($0, kAudioBoxPropertyBoxUID) == boxUID }
}

func setAcquired(_ box: AudioObjectID, _ v: UInt32) -> OSStatus {
    var a = sysAddr(kAudioBoxPropertyAcquired); var val = v
    return AudioObjectSetPropertyData(box, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val)
}

func getAcquired(_ box: AudioObjectID) -> UInt32? {
    var a = sysAddr(kAudioBoxPropertyAcquired); var v: UInt32 = 0
    var s = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(box, &a, 0, nil, &s, &v) == noErr ? v : nil
}

guard let box = findBox() else {
    FileHandle.standardError.write("FAIL: BAM box not found. Install/reload driver.\n".data(using: .utf8)!)
    exit(2)
}
print("Found BAM box id=\(box) acquired=\(getAcquired(box).map(String.init) ?? "nil")")
print("initial: bamDevicePresent=\(bamDevicePresent())")

// Poll up to ~5s for the device list to reflect a target state.
func waitFor(_ want: Bool, timeoutMs: Int = 5000) -> (Bool, Int) {
    let stepMs = 100
    var elapsed = 0
    while elapsed <= timeoutMs {
        if bamDevicePresent() == want { return (true, elapsed) }
        usleep(UInt32(stepMs) * 1000)
        elapsed += stepMs
    }
    return (false, elapsed)
}

// Remove at runtime.
let r0 = setAcquired(box, 0)
let (rmOK, rmMs) = waitFor(false)
print("set acquired=0 status=\(r0) -> removed=\(rmOK) in \(rmMs)ms")

// Re-add at runtime.
let r1 = setAcquired(box, 1)
let (addOK, addMs) = waitFor(true)
print("set acquired=1 status=\(r1) -> readded=\(addOK) in \(addMs)ms")

if r0 == noErr, r1 == noErr, rmOK, addOK {
    print("PASS: device removed + re-added at runtime (no reload). Dynamic publication primitive works.")
    exit(0)
} else {
    print("FAIL: runtime device-list change did not propagate.")
    exit(1)
}
