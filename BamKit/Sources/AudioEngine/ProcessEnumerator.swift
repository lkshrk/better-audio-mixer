import CoreAudio
import Foundation

struct AudioProcessInfo: Sendable, Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    var isRunningOutput: Bool
}

struct OutputDeviceInfo: Sendable, Equatable {
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32
    let dataSource: UInt32
}

enum ProcessEnumerator {
    static func processObjectIDs() -> [AudioObjectID] {
        CA.array(
            AudioObjectID(kAudioObjectSystemObject),
            CA.address(kAudioHardwarePropertyProcessObjectList),
            of: AudioObjectID.self
        )
    }

    static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        CA.uint32(object, CA.address(kAudioProcessPropertyIsRunningOutput)) != 0
    }

    static func info(for object: AudioObjectID) -> AudioProcessInfo? {
        let pidVal = CA.value(
            object, CA.address(kAudioProcessPropertyPID), default: pid_t(-1)
        )
        let bundleID = CA.cfString(object, CA.address(kAudioProcessPropertyBundleID)) ?? ""
        return AudioProcessInfo(
            objectID: object,
            pid: pidVal,
            bundleID: bundleID,
            isRunningOutput: isRunningOutput(object)
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
        let source = CA.uint32Value(object, AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource, mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)) ?? 0
        return OutputDeviceInfo(objectID: object, uid: uid, name: name, transportType: transport, dataSource: source)
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
}

/// The object list is re-read on every call; PID and bundle ID never change for a live object,
/// so only the running flag is refreshed while the list is stable and the snapshot is older than `ttl`.
final class ProcessSnapshotCache: @unchecked Sendable {
    struct Readers: Sendable {
        var objectIDs: @Sendable () -> [AudioObjectID]
        var info: @Sendable (AudioObjectID) -> AudioProcessInfo?
        var isRunningOutput: @Sendable (AudioObjectID) -> Bool

        static let live = Readers(objectIDs: { ProcessEnumerator.processObjectIDs() },
                                  info: { ProcessEnumerator.info(for: $0) },
                                  isRunningOutput: { ProcessEnumerator.isRunningOutput($0) })
    }

    private let lock = NSLock()
    private let readers: Readers
    private let ttl: Duration
    private var objectIDs: [AudioObjectID] = []
    private var processes: [AudioProcessInfo] = []
    private var refreshedAt: ContinuousClock.Instant?

    init(ttl: Duration = .seconds(1), readers: Readers = .live) {
        self.ttl = ttl
        self.readers = readers
    }

    func snapshot(now: ContinuousClock.Instant = .now) -> [AudioProcessInfo] {
        let ids = readers.objectIDs()
        lock.lock()
        defer { lock.unlock() }
        if ids == objectIDs {
            if let refreshedAt, refreshedAt.duration(to: now) < ttl { return processes }
            processes = processes.map { process in
                var refreshed = process
                refreshed.isRunningOutput = readers.isRunningOutput(process.objectID)
                return refreshed
            }
        } else {
            processes = ids.compactMap(readers.info)
            objectIDs = ids
        }
        refreshedAt = now
        return processes
    }

    func invalidate() {
        lock.lock()
        refreshedAt = nil
        lock.unlock()
    }
}
