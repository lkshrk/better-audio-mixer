import CoreAudio
import Foundation

/// Drives the BAM HAL driver's dynamic device publication. The driver exposes a
/// plugin-scope custom property `kBAMProperty_MixConfig` ('bmcf'): an array of
/// `{slot, claimed, name, channels}` dicts. Setting it claims/unclaims virtual
/// devices (`BAM_UID_<slot>`) at runtime — no coreaudiod reload. Until a slot is
/// claimed its device does not exist, so opening it fails (the "Offline" warning).
enum BAMSlotClaim {
    static let bundleID = "me.harke.bam.driver"

    private static func fourCC(_ s: String) -> AudioObjectPropertySelector {
        var r: UInt32 = 0
        for b in s.utf8 { r = (r << 8) | UInt32(b) }
        return r
    }

    private static let mixConfigSelector = fourCC("bmcf")

    private static func globalAddress(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Resolve the BAM plugin object id from its bundle id. nil = driver not installed.
    static func pluginObject() -> AudioObjectID? {
        var addr = globalAddress(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var cf = bundleID as CFString
        var obj: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qsize = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &cf) { qp -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &addr, qsize, qp, &size, &obj)
        }
        return (st == noErr && obj != 0) ? obj : nil
    }

    private static func entry(slot: Int, name: String, channels: Int = 2) -> CFDictionary {
        var s = slot, c = 1, ch = channels
        let d: [CFString: CFTypeRef] = [
            "slot" as CFString: CFNumberCreate(nil, .sInt32Type, &s),
            "claimed" as CFString: CFNumberCreate(nil, .sInt32Type, &c),
            "name" as CFString: name as CFString,
            "channels" as CFString: CFNumberCreate(nil, .sInt32Type, &ch),
        ]
        return d as CFDictionary
    }

    private static func write(_ plugin: AudioObjectID, _ entries: [CFDictionary]) -> OSStatus {
        var addr = globalAddress(mixConfigSelector)
        var arr = entries as CFArray
        return withUnsafeMutablePointer(to: &arr) { p in
            AudioObjectSetPropertyData(plugin, &addr, 0, nil,
                                       UInt32(MemoryLayout<CFArray>.size), p)
        }
    }

    private static func devicePresent(uid: String) -> Bool {
        var addr = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return false }
        let n = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: n)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            var ua = globalAddress(kAudioDevicePropertyDeviceUID)
            var cf: Unmanaged<CFString>?
            var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &ua, 0, nil, &s, &cf) == noErr,
               (cf?.takeRetainedValue() as String?) == uid { return true }
        }
        return false
    }

    /// Claim exactly `slots` (slot → display name). Blocks briefly until each
    /// device publishes. Returns true if the driver was reachable; false = driver
    /// not installed (caller surfaces the slots as failed/offline).
    @discardableResult
    static func claim(_ slots: [Int: String]) -> Bool {
        guard let plugin = pluginObject() else { return false }
        let entries = slots.sorted { $0.key < $1.key }.map { entry(slot: $0.key, name: $0.value) }
        guard write(plugin, entries) == noErr else { return false }
        // Wait for the highest slot to appear (driver publishes within ~100–400ms).
        if let maxSlot = slots.keys.max() {
            let uid = "BAM_UID_\(maxSlot)"
            var waited = 0
            while waited < 2000 && !devicePresent(uid: uid) {
                usleep(50_000); waited += 50
            }
        }
        return true
    }

    /// Release every BAM virtual device.
    static func releaseAll() {
        guard let plugin = pluginObject() else { return }
        _ = write(plugin, [])
    }
}
