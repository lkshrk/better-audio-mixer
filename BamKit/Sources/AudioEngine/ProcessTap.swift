import CoreAudio
import Foundation

/// One Core Audio process tap. Owns the tap object's lifetime; reads its
/// negotiated stream format so the aggregate and RMS loop know the layout.
final class ProcessTap {
    let tapID: AudioObjectID
    let uuid: String
    let format: AudioStreamBasicDescription

    init?(description: CATapDescription) {
        description.isPrivate = true

        var id = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &id) == noErr,
              id != AudioObjectID(kAudioObjectUnknown) else { return nil }

        guard let fmt = ProcessTap.readFormat(id) else {
            AudioHardwareDestroyProcessTap(id)
            return nil
        }

        self.tapID = id
        self.uuid = description.uuid.uuidString
        self.format = fmt
    }

    deinit {
        AudioHardwareDestroyProcessTap(tapID)
    }

    private static func readFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = CA.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        let status = withUnsafeMutablePointer(to: &asbd) {
            AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? asbd : nil
    }
}
