import CoreAudio
import Foundation

struct AudioProcessInfo: Sendable, Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool
    let deviceIDs: [AudioObjectID]
}

struct OutputDeviceInfo: Sendable, Equatable {
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32
}

enum ProcessEnumerator {
    static func processObjectIDs() -> [AudioObjectID] {
        CA.array(
            AudioObjectID(kAudioObjectSystemObject),
            CA.address(kAudioHardwarePropertyProcessObjectList),
            of: AudioObjectID.self
        )
    }

    static func info(for object: AudioObjectID) -> AudioProcessInfo? {
        let pidVal = CA.value(
            object, CA.address(kAudioProcessPropertyPID), default: pid_t(-1)
        )
        let bundleID = CA.cfString(object, CA.address(kAudioProcessPropertyBundleID)) ?? ""
        let running = CA.uint32(object, CA.address(kAudioProcessPropertyIsRunningOutput)) != 0
        let devices: [AudioObjectID] = CA.array(
            object, CA.address(kAudioProcessPropertyDevices), of: AudioObjectID.self
        )
        return AudioProcessInfo(
            objectID: object,
            pid: pidVal,
            bundleID: bundleID,
            isRunningOutput: running,
            deviceIDs: devices
        )
    }

    static func allProcesses() -> [AudioProcessInfo] {
        processObjectIDs().compactMap(info(for:))
    }

    /// Resolve a live PID to its CoreAudio process object. Works even before the
    /// process has rendered (translation instantiates the object on demand),
    /// unlike scanning `processObjectIDs()`.
    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidVal = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &pidVal, &size, &obj
        )
        return st == noErr && obj != AudioObjectID(kAudioObjectUnknown) ? obj : nil
    }

    /// Resolve a device UID string back to its live CoreAudio object.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = CA.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = withUnsafeMutablePointer(to: &cfUID) { p in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<CFString>.size), p, &size, &dev
            )
        }
        return st == noErr && dev != AudioObjectID(kAudioObjectUnknown) ? dev : nil
    }

    static func device(for object: AudioObjectID) -> OutputDeviceInfo? {
        guard let uid = CA.cfString(object, CA.address(kAudioDevicePropertyDeviceUID)) else {
            return nil
        }
        let name = CA.cfString(object, CA.address(kAudioObjectPropertyName))
            ?? CA.cfString(object, CA.address(kAudioDevicePropertyDeviceNameCFString))
            ?? uid
        let transport = CA.uint32(object, CA.address(kAudioDevicePropertyTransportType))
        return OutputDeviceInfo(objectID: object, uid: uid, name: name, transportType: transport)
    }

    static func defaultOutputDeviceUID() -> String? {
        let id = CA.value(
            AudioObjectID(kAudioObjectSystemObject),
            CA.address(kAudioHardwarePropertyDefaultOutputDevice),
            default: AudioObjectID(kAudioObjectUnknown)
        )
        guard id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device(for: id)?.uid
    }

    static func systemOutputDevices() -> [OutputDeviceInfo] {
        let ids: [AudioObjectID] = CA.array(
            AudioObjectID(kAudioObjectSystemObject),
            CA.address(kAudioHardwarePropertyDevices),
            of: AudioObjectID.self
        )
        return ids.compactMap { id in
            let outStreams: [AudioObjectID] = CA.array(
                id,
                CA.address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput),
                of: AudioObjectID.self
            )
            guard !outStreams.isEmpty else { return nil }
            return device(for: id)
        }
    }

    /// Resolve a set of bundle IDs to the live (process, output device) pairs that
    /// should each get their own tap chain.
    static func resolve(bundleIDs: Set<String>) -> [(process: AudioProcessInfo, device: OutputDeviceInfo)] {
        var pairs: [(AudioProcessInfo, OutputDeviceInfo)] = []
        for proc in allProcesses() where bundleIDs.contains(proc.bundleID) {
            for devID in proc.deviceIDs {
                if let dev = device(for: devID) {
                    pairs.append((proc, dev))
                }
            }
        }
        return pairs.map { (process: $0.0, device: $0.1) }
    }
}
