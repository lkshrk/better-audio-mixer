// Step-2b gate: drive dynamic per-mix publication via the plugin-scope kBAMProperty_MixConfig.
// Finds the BAM plugin object, writes a mix config claiming slot 0 ("Stream"), and verifies the
// device BAM_UID_0 appears in the global device list (dynamic publication). Then unclaims and
// verifies it disappears.
//
// Build: swiftc -O mixcfgcheck.swift -o mixcfgcheck -framework CoreAudio -framework Foundation
// Run:   ./mixcfgcheck            (BAM.driver installed/reloaded)
import CoreAudio
import Foundation

let bundleID = "me.harke.bam.driver"

func fourCC(_ s: String) -> AudioObjectPropertySelector {
    var r: UInt32 = 0
    for b in s.utf8 { r = (r << 8) | UInt32(b) }
    return r
}
let kMixConfig = fourCC("bmcf")

func gAddr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func devicePresent(uid: String) -> Bool {
    var a = gAddr(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return false }
    let n = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: n)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return false }
    for id in ids {
        var ua = gAddr(kAudioDevicePropertyDeviceUID); var cf: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &ua, 0, nil, &s, &cf) == noErr, (cf?.takeRetainedValue() as String?) == uid { return true }
    }
    return false
}

func waitFor(uid: String, present want: Bool, timeoutMs: Int = 5000) -> (Bool, Int) {
    var elapsed = 0
    while elapsed <= timeoutMs {
        if devicePresent(uid: uid) == want { return (true, elapsed) }
        usleep(100_000); elapsed += 100
    }
    return (false, elapsed)
}

// Resolve the BAM plugin object id from its bundle id.
func findPlugIn() -> AudioObjectID? {
    var a = gAddr(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
    var cf = bundleID as CFString
    var pid: AudioObjectID = 0
    var s = UInt32(MemoryLayout<AudioObjectID>.size)
    let q = UInt32(MemoryLayout<CFString>.size)
    let st = withUnsafeMutablePointer(to: &cf) { qp -> OSStatus in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, q, qp, &s, &pid)
    }
    return (st == noErr && pid != 0) ? pid : nil
}

func mixEntry(slot: Int, claimed: Int, name: String, channels: Int) -> CFDictionary {
    var s = slot, c = claimed, ch = channels
    let d: [CFString: CFTypeRef] = [
        "slot" as CFString: CFNumberCreate(nil, .sInt32Type, &s),
        "claimed" as CFString: CFNumberCreate(nil, .sInt32Type, &c),
        "name" as CFString: name as CFString,
        "channels" as CFString: CFNumberCreate(nil, .sInt32Type, &ch),
    ]
    return d as CFDictionary
}

func setConfig(_ plugin: AudioObjectID, _ entries: [CFDictionary]) -> OSStatus {
    var a = gAddr(kMixConfig)
    var arr = entries as CFArray
    return withUnsafeMutablePointer(to: &arr) { p in
        AudioObjectSetPropertyData(plugin, &a, 0, nil, UInt32(MemoryLayout<CFArray>.size), p)
    }
}

guard let plugin = findPlugIn() else {
    FileHandle.standardError.write("FAIL: BAM plugin object not found (bundle \(bundleID)). Install/reload driver.\n".data(using: .utf8)!)
    exit(2)
}
print("Found BAM plugin id=\(plugin)")

let uid0 = "BAM_UID_0"
let uid1 = "BAM_UID_1"
print("initial: \(uid0) present=\(devicePresent(uid: uid0)) \(uid1) present=\(devicePresent(uid: uid1))")

// Claim slot 0.
let c1 = setConfig(plugin, [mixEntry(slot: 0, claimed: 1, name: "Stream", channels: 2)])
let (addOK, addMs) = waitFor(uid: uid0, present: true)
print("claim slot0 status=\(c1) -> published=\(addOK) in \(addMs)ms")

// Claim slots 0 AND 1 together (proves slot>0 dispatch works after the 8-slot broadening).
let c1b = setConfig(plugin, [
    mixEntry(slot: 0, claimed: 1, name: "Stream", channels: 2),
    mixEntry(slot: 1, claimed: 1, name: "Chat", channels: 2),
])
let (add1OK, add1Ms) = waitFor(uid: uid1, present: true)
let still0 = devicePresent(uid: uid0)
print("claim slot0+slot1 status=\(c1b) -> slot1 published=\(add1OK) in \(add1Ms)ms, slot0 still present=\(still0)")

// Unclaim (empty config) — both must disappear.
let c2 = setConfig(plugin, [])
let (rmOK, rmMs) = waitFor(uid: uid0, present: false)
let (rm1OK, _) = waitFor(uid: uid1, present: false)
print("unclaim status=\(c2) -> slot0 removed=\(rmOK) in \(rmMs)ms, slot1 removed=\(rm1OK)")

if c1 == noErr, c1b == noErr, c2 == noErr, addOK, add1OK, still0, rmOK, rm1OK {
    print("PASS: dynamic multi-slot publication works (slot0 + slot1 publish independently, unclaim removes both).")
    exit(0)
} else {
    print("FAIL: MixConfig did not drive dynamic multi-slot publication.")
    exit(1)
}
