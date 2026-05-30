import Darwin
import XCTest
@testable import BamControlKit

// MARK: - Test fixture helpers

private func makeMix(id: String = "m-game", name: String = "Game", emoji: String = "🎮",
                     pos: Double = 0.62, muted: Bool = false, level: Float = -18.3) -> MixSnapshot {
    MixSnapshot(id: id, name: name, emoji: emoji,
                pos: pos, pct: Int((pos * 100).rounded()), muted: muted, level: level)
}

private func makeMaster(pos: Double = 0.5, muted: Bool = false, level: Float = -22.1) -> MasterSnapshot {
    MasterSnapshot(pos: pos, pct: Int((pos * 100).rounded()), muted: muted, level: level)
}

// MARK: - Socket helpers

/// Write one NDJSON line to a file-descriptor.
private func writeLine(_ fd: Int32, _ obj: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: obj)
    data.append(0x0A)
    _ = data.withUnsafeBytes { buf -> Int in
        var sent = 0
        while sent < buf.count {
            let n = Darwin.send(fd, buf.baseAddress! + sent, buf.count - sent, 0)
            if n <= 0 { break }
            sent += n
        }
        return sent
    }
}

/// Per-connection receive buffer — persists between readFrame calls so leftover bytes
/// after a newline are not discarded.
final class RecvBuf {
    var data = Data()
}

/// Read one complete NDJSON line from `fd`, using `buf` to accumulate between calls.
/// Yields the MainActor via Task.sleep so Task hops in the server can run.
@MainActor
private func readFrame(_ fd: Int32, buf: RecvBuf, timeout: TimeInterval = 3.0) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        // Check if there's already a complete line in the buffer.
        if let idx = buf.data.firstIndex(of: 0x0A) {
            let lineData = Data(buf.data[buf.data.startIndex ..< idx])
            buf.data = buf.data[buf.data.index(after: idx)...]
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                throw NSError(domain: "readFrame", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "bad JSON"])
            }
            return obj
        }
        // Non-blocking recv to fill the buffer.
        var tmp = [UInt8](repeating: 0, count: 4096)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let n = Darwin.recv(fd, &tmp, tmp.count, 0)
        _ = fcntl(fd, F_SETFL, flags)
        if n > 0 { buf.data.append(contentsOf: tmp.prefix(n)) }
        // Yield so @MainActor Task hops can execute.
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "readFrame", code: 2,
                  userInfo: [NSLocalizedDescriptionKey: "timeout after \(timeout)s"])
}

/// Drain frames until one matching `type` is found.
@MainActor
private func readFrameOfType(_ fd: Int32, buf: RecvBuf, type: String,
                              attempts: Int = 40, timeout: TimeInterval = 3.0) async throws -> [String: Any] {
    for _ in 0..<attempts {
        let f = try await readFrame(fd, buf: buf, timeout: timeout)
        if f["t"] as? String == type { return f }
    }
    throw NSError(domain: "readFrameOfType", code: 3,
                  userInfo: [NSLocalizedDescriptionKey: "never saw frame type '\(type)'"])
}

// MARK: - Frame encode/decode unit tests

final class FrameEncodingTests: XCTestCase {
    func testEncodeRoundTrip() throws {
        let obj: [String: Any] = ["t": "hello-ack", "v": 1, "app": "BAM", "build": "1.0.0"]
        let data = try encodeFrame(obj)
        let back = try decodeFrame(data)
        XCTAssertEqual(back["t"] as? String, "hello-ack")
        XCTAssertEqual(back["v"] as? Int, 1)
        XCTAssertEqual(back["app"] as? String, "BAM")
    }

    func testDecodeInvalidJSONThrows() {
        XCTAssertThrowsError(try decodeFrame("not json".data(using: .utf8)!))
    }
}

// MARK: - MockMixerControl unit tests (pure @MainActor, no sockets)

@MainActor
final class MockMixerControlTests: XCTestCase {

    override func setUp() async throws {}
    override func tearDown() async throws {}

    func testSnapshotReflectsInitialState() {
        let mock = MockMixerControl(mixes: [makeMix()], master: makeMaster())
        let snap = mock.controlSnapshot
        XCTAssertEqual(snap.mixes.count, 1)
        XCTAssertEqual(snap.mixes[0].id, "m-game")
        XCTAssertEqual(snap.master.pos, 0.5)
    }

    func testSetPosMutatesAndRecords() {
        let mock = MockMixerControl(mixes: [makeMix(pos: 0.5)], master: makeMaster())
        mock.setPos(mixID: "m-game", pos: 0.8)
        XCTAssertEqual(mock.controlSnapshot.mixes[0].pos, 0.8)
        XCTAssertEqual(mock.controlSnapshot.mixes[0].pct, 80)
        XCTAssertEqual(mock.calls, [.setPos(mixID: "m-game", pos: 0.8)])
    }

    func testNudgePosClampsAndRecords() {
        let mock = MockMixerControl(mixes: [makeMix(pos: 0.95)], master: makeMaster())
        mock.nudgePos(mixID: "m-game", delta: 0.10)
        XCTAssertEqual(mock.controlSnapshot.mixes[0].pos, 1.0)
        XCTAssertEqual(mock.calls, [.nudgePos(mixID: "m-game", delta: 0.10)])
    }

    func testSetMutedRecords() {
        let mock = MockMixerControl(mixes: [makeMix(muted: false)], master: makeMaster())
        mock.setMuted(mixID: "m-game", muted: true)
        XCTAssertTrue(mock.controlSnapshot.mixes[0].muted)
        XCTAssertEqual(mock.calls, [.setMuted(mixID: "m-game", muted: true)])
    }

    func testToggleMutedRecords() {
        let mock = MockMixerControl(mixes: [makeMix(muted: false)], master: makeMaster())
        mock.toggleMuted(mixID: "m-game")
        XCTAssertTrue(mock.controlSnapshot.mixes[0].muted)
        mock.toggleMuted(mixID: "m-game")
        XCTAssertFalse(mock.controlSnapshot.mixes[0].muted)
        XCTAssertEqual(mock.calls,
                       [.toggleMuted(mixID: "m-game"), .toggleMuted(mixID: "m-game")])
    }

    func testSetMasterPosMutatesAndRecords() {
        let mock = MockMixerControl(mixes: [], master: makeMaster(pos: 0.5))
        mock.setMasterPos(pos: 0.3)
        XCTAssertEqual(mock.controlSnapshot.master.pos, 0.3)
        XCTAssertEqual(mock.controlSnapshot.master.pct, 30)
        XCTAssertEqual(mock.calls, [.setMasterPos(pos: 0.3)])
    }

    func testNudgeMasterPosClampsAndRecords() {
        let mock = MockMixerControl(mixes: [], master: makeMaster(pos: 0.02))
        mock.nudgeMasterPos(delta: -0.05)
        XCTAssertEqual(mock.controlSnapshot.master.pos, 0.0)
        XCTAssertEqual(mock.calls, [.nudgeMasterPos(delta: -0.05)])
    }

    func testSetMasterMutedRecords() {
        let mock = MockMixerControl(mixes: [], master: makeMaster(muted: false))
        mock.setMasterMuted(muted: true)
        XCTAssertTrue(mock.controlSnapshot.master.muted)
        XCTAssertEqual(mock.calls, [.setMasterMuted(muted: true)])
    }

    func testListMixes() {
        let mock = MockMixerControl(mixes: [makeMix(id: "a"), makeMix(id: "b")], master: makeMaster())
        XCTAssertEqual(mock.listMixes().map(\.id), ["a", "b"])
    }

    func testUnknownMixIDIsNoOp() {
        let mock = MockMixerControl(mixes: [makeMix(id: "real")], master: makeMaster())
        mock.setPos(mixID: "nonexistent", pos: 0.5)
        XCTAssertEqual(mock.controlSnapshot.mixes[0].pos, 0.62)
        XCTAssertEqual(mock.calls, [.setPos(mixID: "nonexistent", pos: 0.5)])
    }

    func testListOutputsReturnsScripted() {
        let mock = MockMixerControl(outputs: [
            OutputSnapshot(uid: "A", name: "Speakers", active: true),
            OutputSnapshot(uid: "B", name: "Headphones", active: false),
        ])
        let out = mock.listOutputs()
        XCTAssertEqual(out.map(\.uid), ["A", "B"])
        XCTAssertEqual(out.first(where: { $0.active })?.uid, "A")
    }

    func testSetOutputDeviceV2StubReturnsFalseAndRecords() {
        let mock = MockMixerControl(outputs: [
            OutputSnapshot(uid: "A", name: "Speakers", active: true),
            OutputSnapshot(uid: "B", name: "Headphones", active: false),
        ])
        XCTAssertFalse(mock.setOutputDevice(uid: "B"))
        XCTAssertEqual(mock.listOutputs().first(where: { $0.active })?.uid, "A")
        XCTAssertEqual(mock.calls, [.setOutputDevice(uid: "B")])
    }

    func testSetOutputDeviceV3FlipsActive() {
        let mock = MockMixerControl(outputs: [
            OutputSnapshot(uid: "A", name: "Speakers", active: true),
            OutputSnapshot(uid: "B", name: "Headphones", active: false),
        ])
        mock.outputSwitchSupported = true
        XCTAssertTrue(mock.setOutputDevice(uid: "B"))
        XCTAssertEqual(mock.listOutputs().first(where: { $0.active })?.uid, "B")
    }
}

// MARK: - ControlServer wire-protocol tests

/// Tests use a real UDS so the server's full socket I/O path is exercised.
/// All test methods are `async` so `Task { @MainActor }` hops inside the server
/// can execute while the test yields via `Task.sleep`.
@MainActor
final class ControlServerTests: XCTestCase {

    private var server: ControlServer!
    private var mock: MockMixerControl!
    private var testSockPath: String!

    override func setUp() async throws {
        // Unique temp socket per test so parallel/sequential runs don't collide.
        testSockPath = NSTemporaryDirectory() + "bam-test-\(UUID().uuidString).sock"
        mock = MockMixerControl(mixes: [makeMix()], master: makeMaster())
        server = ControlServer()
        server.socketPath = testSockPath
        server.mixer = mock
        // Seed the snapshot cell before starting so the timer has data immediately.
        server.pushSnapshot(mock.controlSnapshot)
        server.startSync()  // blocks until socket is bound
    }

    /// Push mock's current snapshot into the server (simulates the app's push loop).
    private func pushSnapshot() {
        server.pushSnapshot(mock.controlSnapshot)
    }

    override func tearDown() async throws {
        server.stopSync()
        if let p = testSockPath { try? FileManager.default.removeItem(atPath: p) }
        server = nil
        mock = nil
        testSockPath = nil
    }

    // MARK: - UDS connect helper

    private func connectFD() throws -> Int32 {
        let sockPath = testSockPath!
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "connect", code: Int(errno)) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = sockPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            pathBytes.withUnsafeBytes { src in
                dest.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress,
                                                             count: min(src.count, maxLen)))
            }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else { Darwin.close(fd); throw NSError(domain: "connect", code: Int(errno)) }
        return fd
    }

    /// Perform hello handshake and wait until both hello-ack AND state have been received.
    /// Meter frames may arrive interleaved; this drains until both are seen.
    private func handshake(client: String = "test") async throws -> (Int32, RecvBuf) {
        let fd = try connectFD()
        let buf = RecvBuf()
        try writeLine(fd, ["t": "hello", "v": 1, "client": client])
        var sawAck = false
        var sawState = false
        for _ in 0..<40 {
            let f = try await readFrame(fd, buf: buf)
            switch f["t"] as? String {
            case "hello-ack": sawAck = true
            case "state": sawState = true
            default: break
            }
            if sawAck && sawState { break }
        }
        XCTAssertTrue(sawAck, "Never received hello-ack")
        XCTAssertTrue(sawState, "Never received state")
        return (fd, buf)
    }

    // MARK: - Tests

    func testHelloHandshakeAck() async throws {
        let fd = try connectFD()
        defer { Darwin.close(fd) }
        let buf = RecvBuf()
        try writeLine(fd, ["t": "hello", "v": 1, "client": "streamdeck"])
        let ack = try await readFrame(fd, buf: buf)
        XCTAssertEqual(ack["t"] as? String, "hello-ack")
        XCTAssertEqual(ack["v"] as? Int, 1)
        XCTAssertEqual(ack["app"] as? String, "BAM")
        XCTAssertNotNil(ack["build"])
    }

    func testHelloAckFollowedByStateSnapshot() async throws {
        let fd = try connectFD()
        defer { Darwin.close(fd) }
        let buf = RecvBuf()
        try writeLine(fd, ["t": "hello", "v": 1, "client": "streamdeck"])
        let ack = try await readFrameOfType(fd, buf: buf, type: "hello-ack")
        XCTAssertEqual(ack["t"] as? String, "hello-ack")
        let state = try await readFrameOfType(fd, buf: buf, type: "state")
        XCTAssertNotNil(state["mixes"])
        XCTAssertNotNil(state["master"])
        let mixes = state["mixes"] as? [[String: Any]]
        XCTAssertEqual(mixes?.first?["id"] as? String, "m-game")
    }

    func testVersionMismatchSendsErrorAndCloses() async throws {
        let fd = try connectFD()
        defer { Darwin.close(fd) }
        let buf = RecvBuf()
        try writeLine(fd, ["t": "hello", "v": 99, "client": "streamdeck"])
        let errFrame = try await readFrame(fd, buf: buf)
        XCTAssertEqual(errFrame["t"] as? String, "error")
        XCTAssertEqual(errFrame["code"] as? String, "version")
        // Server closes — wait briefly then expect EOF
        try await Task.sleep(for: .milliseconds(100))
        var tmp = [UInt8](repeating: 0, count: 64)
        let n = Darwin.recv(fd, &tmp, tmp.count, 0)
        XCTAssertLessThanOrEqual(n, 0, "Expected EOF after version mismatch")
    }

    func testCmdSetPosMutatesMock() async throws {
        let (fd, _) = try await handshake()
        defer { Darwin.close(fd) }
        try writeLine(fd, ["t": "cmd", "op": "setPos", "mix": "m-game", "pos": 0.75])
        // Give the MainActor hop time to land
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(mock.calls.contains(.setPos(mixID: "m-game", pos: 0.75)),
                      "calls: \(mock.calls)")
    }

    func testCmdNudgePosMutatesMock() async throws {
        let (fd, _) = try await handshake()
        defer { Darwin.close(fd) }
        try writeLine(fd, ["t": "cmd", "op": "nudgePos", "mix": "m-game", "delta": 0.05])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(mock.calls.contains(.nudgePos(mixID: "m-game", delta: 0.05)))
    }

    func testCmdSetMutedMutatesMock() async throws {
        let (fd, _) = try await handshake()
        defer { Darwin.close(fd) }
        try writeLine(fd, ["t": "cmd", "op": "setMuted", "mix": "m-game", "muted": true])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(mock.calls.contains(.setMuted(mixID: "m-game", muted: true)))
    }

    func testCmdToggleMutedMutatesMock() async throws {
        let (fd, _) = try await handshake()
        defer { Darwin.close(fd) }
        try writeLine(fd, ["t": "cmd", "op": "toggleMuted", "mix": "m-game"])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(mock.calls.contains(.toggleMuted(mixID: "m-game")))
    }

    func testCmdSetMasterPosMutatesMock() async throws {
        let (fd, _) = try await handshake()
        defer { Darwin.close(fd) }
        try writeLine(fd, ["t": "cmd", "op": "setMasterPos", "pos": 0.3])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(mock.calls.contains(.setMasterPos(pos: 0.3)))
    }

    func testCmdNudgeMasterPosMutatesMock() async throws {
        let (fd, _) = try await handshake()
        defer { Darwin.close(fd) }
        try writeLine(fd, ["t": "cmd", "op": "nudgeMasterPos", "delta": -0.03])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(mock.calls.contains(.nudgeMasterPos(delta: -0.03)))
    }

    func testCmdSetMasterMutedMutatesMock() async throws {
        let (fd, _) = try await handshake()
        defer { Darwin.close(fd) }
        try writeLine(fd, ["t": "cmd", "op": "setMasterMuted", "muted": true])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(mock.calls.contains(.setMasterMuted(muted: true)))
    }

    func testListMixesResponse() async throws {
        let (fd, buf) = try await handshake()
        defer { Darwin.close(fd) }
        try writeLine(fd, ["t": "listMixes"])
        let mixesFrame = try await readFrameOfType(fd, buf: buf, type: "mixes")
        let mixes = mixesFrame["mixes"] as? [[String: Any]]
        XCTAssertEqual(mixes?.first?["id"] as? String, "m-game")
        XCTAssertEqual(mixes?.first?["name"] as? String, "Game")
        XCTAssertNotNil(mixes?.first?["emoji"])
    }

    func testListOutputsResponse() async throws {
        mock.outputs = [
            OutputSnapshot(uid: "A", name: "Speakers", active: true, icon: "hifispeaker.fill"),
            OutputSnapshot(uid: "B", name: "Headphones", active: false, icon: "headphones"),
        ]
        let (fd, buf) = try await handshake()
        defer { Darwin.close(fd) }
        try writeLine(fd, ["t": "listOutputs"])
        let frame = try await readFrameOfType(fd, buf: buf, type: "outputs")
        let outputs = frame["outputs"] as? [[String: Any]]
        XCTAssertEqual(outputs?.map { $0["uid"] as? String }, ["A", "B"])
        XCTAssertEqual(outputs?.first?["name"] as? String, "Speakers")
        XCTAssertEqual(outputs?.first?["active"] as? Bool, true)
        XCTAssertEqual(outputs?.first?["icon"] as? String, "hifispeaker.fill")
        XCTAssertEqual(outputs?.last?["icon"] as? String, "headphones")
    }

    func testMeterFrameArrivesAfterHandshake() async throws {
        let (fd, buf) = try await handshake()
        defer { Darwin.close(fd) }
        // Timer fires at ~83ms; wait up to 3 attempts
        let meterFrame = try await readFrameOfType(fd, buf: buf, type: "meter")
        XCTAssertNotNil(meterFrame["mixes"])
        XCTAssertNotNil(meterFrame["master"])
        let master = meterFrame["master"] as? [String: Any]
        XCTAssertNotNil(master?["level"])
    }

    func testMultiClientFanOut() async throws {
        let (fd1, buf1) = try await handshake(client: "deck1")
        let (fd2, buf2) = try await handshake(client: "deck2")
        defer { Darwin.close(fd1); Darwin.close(fd2) }

        // Both receive meter frames from the shared timer
        let m1 = try await readFrameOfType(fd1, buf: buf1, type: "meter")
        let m2 = try await readFrameOfType(fd2, buf: buf2, type: "meter")
        XCTAssertEqual(m1["t"] as? String, "meter")
        XCTAssertEqual(m2["t"] as? String, "meter")
    }

    func testDeadClientPrunedOnEPIPE() async throws {
        let (fd, _) = try await handshake(client: "dying")
        Darwin.close(fd) // close without notifying server

        // Wait for at least one meter tick to hit EPIPE and prune
        try await Task.sleep(for: .milliseconds(500))

        // Server should still accept new connections (not crashed/deadlocked)
        let (fd2, _) = try await handshake(client: "alive")
        defer { Darwin.close(fd2) }
        // If we got here, the server survived the dead client
        XCTAssert(true)
    }

    func testSnapshotDiffEmitsDeltaOnPosChange() async throws {
        let (fd, buf) = try await handshake()
        defer { Darwin.close(fd) }

        // Consume frames until we have seen at least one meter — this guarantees
        // lastSnapshot is populated inside the server's broadcastDiff.
        _ = try await readFrameOfType(fd, buf: buf, type: "meter")

        // Mutate and push new snapshot so the next tick detects the pos change.
        mock.setPos(mixID: "m-game", pos: 0.99)
        pushSnapshot()

        // Wait slightly longer than one tick so the timer definitely fires after the push.
        try await Task.sleep(for: .milliseconds(200))

        // Drain frames looking for a delta. Each readFrame call waits up to 0.3s;
        // continue on timeout (nil from try?), break only when we find the delta.
        var deltaFrame: [String: Any]? = nil
        for _ in 0..<80 {
            let f = try? await readFrame(fd, buf: buf, timeout: 0.3)
            if let f, f["t"] as? String == "delta" { deltaFrame = f; break }
            // nil = timeout (no frame yet) — keep waiting
        }
        guard let deltaFrame else {
            XCTFail("Never received delta frame after pos change")
            return
        }
        XCTAssertEqual(deltaFrame["mix"] as? String, "m-game")
        XCTAssertEqual(deltaFrame["pos"] as? Double, 0.99)
        XCTAssertNotNil(deltaFrame["muted"])
        XCTAssertNil(deltaFrame["level"], "Level must not appear in delta frame")
    }

    func testSnapshotDiffMeterOnlyNoUnneededDelta() async throws {
        let (fd, buf) = try await handshake()
        defer { Darwin.close(fd) }

        // Wait for the first meter tick so lastSnapshot is set.
        _ = try await readFrameOfType(fd, buf: buf, type: "meter")

        // No mutations — subsequent frames should be meter only.
        var sawDelta = false
        for _ in 0..<8 {
            if let f = try? await readFrame(fd, buf: buf, timeout: 0.3),
               f["t"] as? String == "delta" { sawDelta = true; break }
        }
        XCTAssertFalse(sawDelta, "No delta expected when pos/mute unchanged")
    }
}
