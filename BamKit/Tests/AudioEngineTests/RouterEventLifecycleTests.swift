import CoreAudio
import XCTest
@testable import AudioEngine

final class RouterEventLifecycleTests: XCTestCase {
    func testRouterEventsReleasesChangeListenersWhenStreamTerminates() async {
        let engine = CoreAudioEngine()
        let active = ManagedCounter()

        await CoreAudioEngine.setChangeListenerFactoryForTests { _, _, onChange in
            active.increment()
            return AnyChangeListenerToken {
                active.decrement()
                _ = onChange
            }
        }
        defer {
            Task { await CoreAudioEngine.setChangeListenerFactoryForTests(nil) }
        }

        let stream = await engine.routerEvents()
        let task = Task {
            for await _ in stream {}
        }

        let created = await eventually { active.value == 3 }
        XCTAssertTrue(created, "routerEvents should install process/device/default-output listeners")

        task.cancel()

        let released = await eventually { active.value == 0 }
        XCTAssertTrue(released, "cancelling the stream should release CoreAudio listeners")
    }

    private func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func decrement() {
        lock.lock()
        count -= 1
        lock.unlock()
    }
}

