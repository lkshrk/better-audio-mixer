import CoreAudio
import Foundation

protocol ChangeListenerToken: AnyObject, Sendable {
    var isActive: Bool { get }
}

extension ChangeListenerToken {
    var isActive: Bool { true }
}

final class AnyChangeListenerToken: ChangeListenerToken, @unchecked Sendable {
    private let onDeinit: @Sendable () -> Void

    init(_ onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

/// Registers a Core Audio property listener and invokes `onChange` whenever the property fires.
final class ChangeListener: ChangeListenerToken, @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue = DispatchQueue(label: "bam.change-listener")
    private let block: AudioObjectPropertyListenerBlock
    let isActive: Bool

    init(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.object = object
        self.address = CA.address(selector)
        self.block = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        isActive = status == noErr
        if status != noErr {
            engineLog.error("change listener registration failed object=\(object, privacy: .public) selector=\(selector, privacy: .public) status=\(status, privacy: .public)")
        }
    }

    deinit {
        if isActive { AudioObjectRemovePropertyListenerBlock(object, &address, queue, block) }
    }
}

/// Collapses bursts of change notifications into one delivery after `delay`.
final class DebouncedTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Task<Void, Never>?
    private let delay: Duration
    private let action: @Sendable () -> Void

    init(delay: Duration, action: @escaping @Sendable () -> Void) {
        self.delay = delay
        self.action = action
    }

    func fire() {
        lock.lock()
        pending?.cancel()
        pending = Task { [delay, action] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        pending?.cancel()
        pending = nil
        lock.unlock()
    }
}
