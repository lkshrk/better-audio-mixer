import CoreAudio
import Foundation

/// Registers a Core Audio property listener and invokes `onChange` whenever the
/// property fires. Used to watch the process list so the engine rebuilds chains
/// when apps start or stop producing audio.
final class ChangeListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue = DispatchQueue(label: "bam.change-listener")
    private let block: AudioObjectPropertyListenerBlock

    init(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.object = object
        self.address = CA.address(selector)
        self.block = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
