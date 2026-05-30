import CoreAudio
import Foundation

enum CA {
    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func dataSize(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
        var size: UInt32 = 0
        var a = addr
        let status = AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size)
        return status == noErr ? size : nil
    }

    static func array<T>(
        _ object: AudioObjectID,
        _ addr: AudioObjectPropertyAddress,
        of type: T.Type
    ) -> [T] {
        guard let size = dataSize(object, addr), size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<T>.alignment
        )
        defer { raw.deallocate() }
        var a = addr
        var io = size
        let status = AudioObjectGetPropertyData(object, &a, 0, nil, &io, raw)
        guard status == noErr else { return [] }
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    static func value<T>(
        _ object: AudioObjectID,
        _ addr: AudioObjectPropertyAddress,
        default def: T
    ) -> T {
        var value = def
        var a = addr
        var io = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &io, $0)
        }
        return status == noErr ? value : def
    }

    static func cfString(
        _ object: AudioObjectID,
        _ addr: AudioObjectPropertyAddress
    ) -> String? {
        var value: CFString? = nil
        var a = addr
        var io = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &io, $0)
        }
        guard status == noErr, let s = value else { return nil }
        return s as String
    }

    static func uint32(
        _ object: AudioObjectID,
        _ addr: AudioObjectPropertyAddress
    ) -> UInt32 {
        value(object, addr, default: UInt32(0))
    }

    static func float64(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Double? {
        var v: Float64 = 0
        var a = addr
        var io = UInt32(MemoryLayout<Float64>.size)
        let st = withUnsafeMutablePointer(to: &v) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &io, $0)
        }
        return st == noErr ? v : nil
    }

    static func float32(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Float? {
        var v: Float32 = 0
        var a = addr
        var io = UInt32(MemoryLayout<Float32>.size)
        let st = withUnsafeMutablePointer(to: &v) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &io, $0)
        }
        return st == noErr ? v : nil
    }

    static func isSettable(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        var settable: DarwinBoolean = false
        let st = AudioObjectIsPropertySettable(object, &a, &settable)
        return st == noErr && settable.boolValue
    }

    @discardableResult
    static func setFloat32(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: Float) -> Bool {
        var v: Float32 = value
        var a = addr
        let st = withUnsafeMutablePointer(to: &v) {
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), $0)
        }
        return st == noErr
    }

    @discardableResult
    static func setUInt32(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: UInt32) -> Bool {
        var v: UInt32 = value
        var a = addr
        let st = withUnsafeMutablePointer(to: &v) {
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), $0)
        }
        return st == noErr
    }
}
