import CoreAudio
import Foundation

protocol ChangeListenerToken: AnyObject, Sendable {}

final class AnyChangeListenerToken: ChangeListenerToken, @unchecked Sendable {
    private let onDeinit: @Sendable () -> Void

    init(_ onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

/// Registers a Core Audio property listener and invokes `onChange` whenever the
/// property fires. Used to watch the process list so the engine rebuilds chains
/// when apps start or stop producing audio.
final class ChangeListener: ChangeListenerToken, @unchecked Sendable {
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
