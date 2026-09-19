import BamCore
import Foundation
import os

// MARK: - Wire protocol version

private let kProtocolVersion = 1
private let kAppName = "BAM"
private let kFallbackBuildVersion = "1.0.7"
private let kMaxClients = 16
private let kMaxReadBuffer = 64 * 1024

private var buildVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? kFallbackBuildVersion
}

private enum ControlLog {
    static let logger = Logger(subsystem: "me.harke.bam", category: "control")
}

public struct ControlServerDiagnostics: Sendable, Equatable {
    public var isListening: Bool
    public var activeClients: Int
    public var acceptedClients: Int
    public var removedClients: Int
    public var malformedFrames: Int
    public var versionRejects: Int
    public var sendFailures: Int
    public var droppedFrames: Int = 0
    public var slowClientEvictions: Int = 0
    public var handshakeTimeouts: Int = 0
    public var rejectedClients: Int = 0
}

// MARK: - NDJSON framing helpers

public enum FrameError: Error { case invalidUTF8, malformedJSON, unencodable }

/// Encode a JSON-serialisable dictionary to a single NDJSON line (no newline appended).
public func encodeFrame(_ obj: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(obj) else { throw FrameError.unencodable }
    return try JSONSerialization.data(withJSONObject: obj)
}

/// Decode one NDJSON line (must not contain a newline) into a dictionary.
public func decodeFrame(_ data: Data) throws -> [String: Any] {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FrameError.malformedJSON
    }
    return obj
}

// MARK: - Thread-safe snapshot cell

/// Lock-protected cell holding the latest ControlSnapshot; written from @MainActor, read by the bgQueue timer.
final class SnapshotCell: @unchecked Sendable {
    private var _value: ControlSnapshot?
    private let lock = NSLock()

    func push(_ snap: ControlSnapshot) {
        lock.lock(); defer { lock.unlock() }
        _value = snap
    }

    func read() -> ControlSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}

// MARK: - Client

/// One connected client; all mutations happen on the server's bgQueue.
final class Client: Hashable, @unchecked Sendable {
    let fd: Int32
    let acceptedAt: ContinuousClock.Instant
    var handshakeDone = false
    var needsInitialState = false
    var clientName: String?
    var readBuffer = Data()
    var recvBuffer = [UInt8](repeating: 0, count: 4096)
    private(set) var lastSendError: Int32?
    /// Frames dropped since the last frame the peer fully absorbed.
    private(set) var consecutiveDrops = 0
    private var pending = Data()

    var peerClosedDuringSend: Bool {
        lastSendError == EPIPE || lastSendError == ECONNRESET
    }

    init(fd: Int32, acceptedAt: ContinuousClock.Instant = .now) {
        self.fd = fd
        self.acceptedAt = acceptedAt
    }

    static func == (lhs: Client, rhs: Client) -> Bool { lhs.fd == rhs.fd }
    func hash(into hasher: inout Hasher) { hasher.combine(fd) }

    /// Returns false on a fatal socket error or when the frame cannot be encoded.
    func send(_ obj: [String: Any]) -> Bool {
        do {
            return sendFrame(try encodeFrame(obj))
        } catch {
            ControlLog.logger.error("frame encode failed fd=\(self.fd, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Returns false on a fatal socket error. A frame the peer cannot absorb yet is dropped and counted, never queued.
    func sendFrame(_ data: Data) -> Bool {
        lastSendError = nil
        if !pending.isEmpty {
            guard flushPending() else { return false }
            if !pending.isEmpty {
                consecutiveDrops += 1
                return true
            }
        }
        var line = data
        line.append(0x0A)
        guard let written = write(line) else { return false }
        if written < line.count {
            pending = Data(line[written...])
        }
        consecutiveDrops = 0
        return true
    }

    var hasPending: Bool { !pending.isEmpty }

    /// Pushes out the tail of a partially written frame. Returns false on a fatal socket error.
    func flush() -> Bool {
        lastSendError = nil
        return pending.isEmpty || flushPending()
    }

    func close() { Darwin.close(fd) }

    private func flushPending() -> Bool {
        guard let written = write(pending) else { return false }
        pending = written == pending.count ? Data() : Data(pending[(pending.startIndex + written)...])
        return true
    }

    /// Bytes written, or nil on a fatal error; a would-block stops early with a short count.
    private func write(_ data: Data) -> Int? {
        data.withUnsafeBytes { buf -> Int? in
            var sent = 0
            while sent < buf.count {
                let n = Darwin.send(fd, buf.baseAddress! + sent, buf.count - sent, MSG_NOSIGNAL)
                if n < 0 {
                    let error = errno
                    if error == EINTR { continue }
                    if error == EAGAIN || error == EWOULDBLOCK { return sent }
                    lastSendError = error
                    return nil
                }
                if n == 0 { return nil }
                sent += n
            }
            return sent
        }
    }
}

// MARK: - ControlServer

/// Unix-domain-socket server: all socket I/O and `Client` state live on `bgQueue`; mixer calls are applied in arrival order by one @MainActor task.
public final class ControlServer: @unchecked Sendable {

    // MARK: - Public interface

    public weak var mixer: (any MixerControl)?

    /// Override to use a custom socket path (e.g. unique per test).
    public var socketPath: String? = nil

    /// Consecutive dropped frames after which a client that stopped reading is evicted.
    public var maxConsecutiveDrops = 60
    /// Time a connected client may stay without completing the hello handshake.
    public var handshakeTimeout: Duration = .seconds(5)
    /// Upper bound applied to every control-originated master position.
    public var masterPosCeiling: Double = 1.0
    /// Minimum spacing between control-originated master writes; writes inside the window are coalesced, not lost.
    public var masterWriteInterval: Duration = .milliseconds(50)

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: MainJob.self)
        jobs = continuation
        jobConsumer = Task { @MainActor [weak self] in
            for await job in stream {
                guard let self else { return }
                await self.perform(job)
            }
        }
    }

    deinit {
        jobs.finish()
        jobConsumer?.cancel()
    }

    /// Start listening. Safe to call multiple times (no-op if already running).
    public func start() {
        bgQueue.async { [weak self] in self?.listen() }
    }

    /// Start listening synchronously — blocks until the socket is bound.
    public func startSync() {
        bgQueue.sync { self.listen() }
    }

    /// Stop the server and close all connections (async).
    public func stop() {
        bgQueue.async { [weak self] in self?.stopListening() }
    }

    /// Stop the server synchronously — blocks until the bgQueue has processed the stop.
    public func stopSync() {
        bgQueue.sync { self.stopListening() }
    }

    /// Push a new snapshot from @MainActor whenever the model changes; the server broadcasts it to clients.
    public func pushSnapshot(_ snap: ControlSnapshot) {
        snapshotCell.push(snap)
    }

    public func diagnosticsSnapshot() -> ControlServerDiagnostics {
        bgQueue.sync {
            ControlServerDiagnostics(
                isListening: serverFD >= 0,
                activeClients: clients.count,
                acceptedClients: acceptedClients,
                removedClients: removedClients,
                malformedFrames: malformedFrames,
                versionRejects: versionRejects,
                sendFailures: sendFailures,
                droppedFrames: droppedFrames,
                slowClientEvictions: slowClientEvictions,
                handshakeTimeouts: handshakeTimeouts,
                rejectedClients: rejectedClients
            )
        }
    }

    // MARK: - Internal state (bgQueue only, except snapshotCell and the MainActor-only master gate)

    private let bgQueue = DispatchQueue(label: "me.harke.bam.controlserver", qos: .utility)
    private let snapshotCell = SnapshotCell()
    private var serverFD: Int32 = -1
    private var boundPath: String?
    private var clients: Set<Client> = []
    private var timerSource: DispatchSourceTimer?
    private var acceptSource: DispatchSourceRead?
    private var readSources: [Int32: DispatchSourceRead] = [:]
    private var lastSnapshot: ControlSnapshot? = nil
    private var acceptedClients = 0
    private var removedClients = 0
    private var malformedFrames = 0
    private var versionRejects = 0
    private var sendFailures = 0
    private var droppedFrames = 0
    private var slowClientEvictions = 0
    private var handshakeTimeouts = 0
    private var rejectedClients = 0

    private let jobs: AsyncStream<MainJob>.Continuation
    private var jobConsumer: Task<Void, Never>?

    private var lastMasterWrite: ContinuousClock.Instant?
    private var pendingMaster: MasterWrite?
    private var masterFlush: Task<Void, Never>?

    // MARK: - Socket path

    private var resolvedSocketPath: String {
        if let p = socketPath { return p }
        try? FileManager.default.createDirectory(at: BamPaths.socketDirectory(), withIntermediateDirectories: true)
        return BamPaths.controlSocketURL().path
    }

    // MARK: - Listen

    private func listen() {
        guard serverFD == -1 else {
            ControlLog.logger.debug("listen ignored; already running")
            return
        }

        let sockPath = resolvedSocketPath
        var addr = sockaddr_un()
        let pathBytes = sockPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            ControlLog.logger.error("socket path too long bytes=\(pathBytes.count, privacy: .public) max=\(maxLen, privacy: .public)")
            return
        }
        unlink(sockPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            ControlLog.logger.error("socket failed errno=\(errno, privacy: .public)")
            return
        }

        let oldMask = umask(0o177)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            pathBytes.withUnsafeBytes { src in
                dest.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: src.count))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)

        guard bindResult == 0 else {
            ControlLog.logger.error("bind failed errno=\(errno, privacy: .public) path=\(sockPath, privacy: .private)")
            Darwin.close(fd)
            return
        }
        guard Darwin.listen(fd, 8) == 0 else {
            ControlLog.logger.error("listen failed errno=\(errno, privacy: .public) path=\(sockPath, privacy: .private)")
            Darwin.close(fd)
            unlink(sockPath)
            return
        }

        serverFD = fd
        boundPath = sockPath

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: bgQueue)
        src.setEventHandler { [weak self] in self?.acceptClient() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        acceptSource = src

        startMeterTimer()
        ControlLog.logger.notice("listening path=\(sockPath, privacy: .private)")
    }

    private func stopListening() {
        ControlLog.logger.notice("stopping clients=\(self.clients.count, privacy: .public)")
        timerSource?.cancel(); timerSource = nil
        acceptSource?.cancel(); acceptSource = nil
        serverFD = -1
        clients = []
        let sources = readSources
        readSources = [:]
        sources.values.forEach { $0.cancel() }
        if let path = boundPath {
            unlink(path)
            boundPath = nil
        }
    }

    // MARK: - Accept

    private func acceptClient() {
        let clientFD = Darwin.accept(serverFD, nil, nil)
        guard clientFD >= 0 else {
            ControlLog.logger.warning("accept failed errno=\(errno, privacy: .public)")
            return
        }
        guard clients.count < kMaxClients else {
            rejectedClients += 1
            ControlLog.logger.warning("client rejected, limit reached fd=\(clientFD, privacy: .public)")
            Darwin.close(clientFD)
            return
        }
        let flags = fcntl(clientFD, F_GETFL)
        _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)
        let client = Client(fd: clientFD)
        clients.insert(client)
        acceptedClients += 1
        let src = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: bgQueue)
        src.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.readData(from: client)
        }
        src.setCancelHandler { Darwin.close(clientFD) }
        src.resume()
        readSources[clientFD] = src
        ControlLog.logger.info("client accepted fd=\(clientFD, privacy: .public) clients=\(self.clients.count, privacy: .public)")
    }

    // MARK: - Read

    private func readData(from client: Client) {
        let n = client.recvBuffer.withUnsafeMutableBytes { buf in
            Darwin.recv(client.fd, buf.baseAddress, buf.count, 0)
        }
        if n <= 0 {
            if n < 0 {
                let error = errno
                if error == EAGAIN || error == EWOULDBLOCK || error == EINTR { return }
                ControlLog.logger.warning("client recv failed fd=\(client.fd, privacy: .public) errno=\(error, privacy: .public)")
            } else {
                ControlLog.logger.info("client disconnected fd=\(client.fd, privacy: .public)")
            }
            removeClient(client)
            return
        }
        client.readBuffer.append(client.recvBuffer, count: n)
        processLines(client: client)
        if client.readBuffer.count > kMaxReadBuffer {
            malformedFrames += 1
            ControlLog.logger.warning("dropping client with oversized line fd=\(client.fd, privacy: .public) bytes=\(client.readBuffer.count, privacy: .public)")
            removeClient(client)
        }
    }

    private func processLines(client: Client) {
        while let idx = client.readBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(client.readBuffer[client.readBuffer.startIndex ..< idx])
            client.readBuffer.removeSubrange(client.readBuffer.startIndex ... idx)
            if lineData.isEmpty { continue }
            handleFrame(lineData, client: client)
        }
    }

    private func removeClient(_ client: Client) {
        if clients.remove(client) != nil {
            removedClients += 1
        }
        if let src = readSources.removeValue(forKey: client.fd) {
            src.cancel()
        } else {
            client.close()
        }
        ControlLog.logger.info("client removed fd=\(client.fd, privacy: .public) clients=\(self.clients.count, privacy: .public)")
    }

    /// Sends one pre-encoded frame, counting drops. Returns false on a fatal socket error.
    private func deliver(_ frame: Data, to client: Client) -> Bool {
        let before = client.consecutiveDrops
        guard client.sendFrame(frame) else { return false }
        if client.consecutiveDrops > before { droppedFrames += 1 }
        return true
    }

    private func reply(_ frame: Data, to client: Client) {
        bgQueue.async { [weak self] in
            guard let self, self.clients.contains(where: { $0 === client }) else { return }
            if !self.deliver(frame, to: client) {
                self.sendFailures += 1
                self.removeClient(client)
            }
        }
    }

    // MARK: - Frame dispatch

    private func handleFrame(_ data: Data, client: Client) {
        guard let obj = try? decodeFrame(data), let t = obj["t"] as? String else {
            malformedFrames += 1
            ControlLog.logger.warning("dropping malformed frame fd=\(client.fd, privacy: .public) bytes=\(data.count, privacy: .public)")
            return
        }
        if t == "hello" {
            handleHello(obj, client: client)
            return
        }
        guard client.handshakeDone else { return }
        switch t {
        case "cmd":             handleCmd(obj, client: client)
        case "listMixes":       jobs.yield(.listMixes(client))
        case "listOutputs":     jobs.yield(.listOutputs(client))
        case "diagnostics":     jobs.yield(.diagnostics(client))
        case "setOutputDevice":
            guard let uid = obj["uid"] as? String else { return }
            jobs.yield(.setOutputDevice(uid: uid, client: client))
        default: break
        }
    }

    // MARK: - Hello

    private func handleHello(_ obj: [String: Any], client: Client) {
        let v = obj["v"] as? Int ?? 0
        guard v == kProtocolVersion else {
            versionRejects += 1
            ControlLog.logger.warning("client version rejected fd=\(client.fd, privacy: .public) version=\(v, privacy: .public)")
            _ = client.send(["t": "error", "code": "version"])
            removeClient(client)
            return
        }
        client.clientName = obj["client"] as? String
        client.handshakeDone = true
        client.needsInitialState = true
        _ = client.send(["t": "hello-ack", "v": kProtocolVersion,
                         "app": kAppName, "build": buildVersion])
        ControlLog.logger.notice("client handshaked fd=\(client.fd, privacy: .public) name=\(client.clientName ?? "unknown", privacy: .private)")
    }

    // MARK: - Commands (parsed on bgQueue, applied in order on @MainActor)

    struct Command: Sendable {
        let op: String
        let mixID: String?
        let pos: Double?
        let delta: Double?
        let muted: Bool?
        let fd: Int32
        let receivedAt: TimeInterval
    }

    enum MainJob: Sendable {
        case command(Command)
        case listMixes(Client)
        case listOutputs(Client)
        case diagnostics(Client)
        case setOutputDevice(uid: String, client: Client)
    }

    private enum MasterWrite {
        case set(Double)
        case nudge(Double)

        func merged(with next: MasterWrite) -> MasterWrite {
            switch (self, next) {
            case (_, .set): return next
            case (.set(let p), .nudge(let d)): return .set(p + d)
            case (.nudge(let a), .nudge(let b)): return .nudge(a + b)
            }
        }
    }

    private static let masterOps: Set<String> = ["setMasterPos", "nudgeMasterPos", "setMasterMuted"]

    private func handleCmd(_ obj: [String: Any], client: Client) {
        guard let op = obj["op"] as? String else { return }
        let cmd = Command(op: op,
                          mixID: obj["mix"] as? String,
                          pos: obj["pos"] as? Double,
                          delta: obj["delta"] as? Double,
                          muted: obj["muted"] as? Bool,
                          fd: client.fd,
                          receivedAt: ProcessInfo.processInfo.systemUptime)
        if Self.masterOps.contains(op) {
            ControlLog.logger.notice("master command received fd=\(client.fd, privacy: .public) op=\(op, privacy: .public) pos=\(cmd.pos ?? .nan, privacy: .public) delta=\(cmd.delta ?? .nan, privacy: .public) muted=\(String(describing: cmd.muted), privacy: .public)")
        }
        jobs.yield(.command(cmd))
    }

    private struct DiagnosticsFrame: Encodable {
        let t = "diagnostics"
        let audio: AudioDiagnostics?
    }

    @MainActor
    private func perform(_ job: MainJob) async {
        guard let mixer else { return }
        switch job {
        case .command(let cmd):
            apply(cmd, mixer: mixer)
        case .listMixes(let client):
            let mixes = mixer.listMixes().map { m -> [String: Any] in
                ["id": m.id, "name": m.name, "emoji": m.emoji]
            }
            replyObject(["t": "mixes", "mixes": mixes], to: client)
        case .listOutputs(let client):
            let outputs = mixer.listOutputs().map { o -> [String: Any] in
                ["uid": o.uid, "name": o.name, "active": o.active, "icon": o.icon]
            }
            replyObject(["t": "outputs", "outputs": outputs], to: client)
        case .diagnostics(let client):
            let snapshot = await mixer.audioDiagnostics()
            guard let frame = try? JSONEncoder().encode(DiagnosticsFrame(audio: snapshot)) else { return }
            reply(frame, to: client)
        case .setOutputDevice(let uid, let client):
            if mixer.setOutputDevice(uid: uid) {
                replyObject(["t": "outputs-ack", "uid": uid], to: client)
            } else {
                ControlLog.logger.warning("unsupported output uid=\(uid, privacy: .private)")
                replyObject(["t": "error", "code": "unsupported", "op": "setOutputDevice"], to: client)
            }
        }
    }

    @MainActor
    private func replyObject(_ obj: [String: Any], to client: Client) {
        do {
            reply(try encodeFrame(obj), to: client)
        } catch {
            ControlLog.logger.error("reply encode failed fd=\(client.fd, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    @MainActor
    private func apply(_ cmd: Command, mixer: any MixerControl) {
        if Self.masterOps.contains(cmd.op) {
            let delay = (ProcessInfo.processInfo.systemUptime - cmd.receivedAt) * 1000
            ControlLog.logger.notice("master command executing fd=\(cmd.fd, privacy: .public) op=\(cmd.op, privacy: .public) queuedMs=\(delay, privacy: .public)")
        }
        switch cmd.op {
        case "setPos":
            guard let id = cmd.mixID, let pos = cmd.pos, pos.isFinite else { return }
            mixer.setPos(mixID: id, pos: pos)
        case "nudgePos":
            guard let id = cmd.mixID, let delta = cmd.delta, delta.isFinite else { return }
            mixer.nudgePos(mixID: id, delta: delta)
        case "setMuted":
            guard let id = cmd.mixID, let muted = cmd.muted else { return }
            mixer.setMuted(mixID: id, muted: muted)
        case "toggleMuted":
            guard let id = cmd.mixID else { return }
            mixer.toggleMuted(mixID: id)
        case "setMasterPos":
            guard let pos = cmd.pos, pos.isFinite else { return }
            scheduleMaster(.set(min(1, max(0, pos))))
        case "nudgeMasterPos":
            guard let delta = cmd.delta, delta.isFinite else { return }
            scheduleMaster(.nudge(delta))
        case "setMasterMuted":
            guard let muted = cmd.muted else { return }
            mixer.setMasterMuted(muted: muted)
        default:
            ControlLog.logger.warning("unknown command op=\(cmd.op, privacy: .public)")
        }
    }

    @MainActor
    private func scheduleMaster(_ write: MasterWrite) {
        let now = ContinuousClock.now
        if let last = lastMasterWrite, now - last < masterWriteInterval {
            pendingMaster = pendingMaster.map { $0.merged(with: write) } ?? write
            if masterFlush == nil {
                let wait = masterWriteInterval - (now - last)
                masterFlush = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: wait)
                    guard let self else { return }
                    self.masterFlush = nil
                    guard let pending = self.pendingMaster else { return }
                    self.pendingMaster = nil
                    self.writeMaster(pending)
                }
            }
            return
        }
        writeMaster(write)
    }

    @MainActor
    private func writeMaster(_ write: MasterWrite) {
        guard let mixer else { return }
        lastMasterWrite = .now
        switch write {
        case .set(let pos):
            mixer.setMasterPos(pos: min(pos, masterPosCeiling))
        case .nudge(let delta):
            if mixer.controlSnapshot.master.pos + delta > masterPosCeiling {
                mixer.setMasterPos(pos: masterPosCeiling)
            } else {
                mixer.nudgeMasterPos(delta: delta)
            }
        }
    }

    // MARK: - Meter timer (~30 fps) — reads snapshotCell directly, no actor hop

    private func startMeterTimer() {
        let timer = DispatchSource.makeTimerSource(queue: bgQueue)
        timer.schedule(deadline: .now() + .milliseconds(33),
                       repeating: .milliseconds(33), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        timerSource = timer
    }

    private func tick() {
        evictStaleHandshakes()
        flushPendingWrites()
        let handshaked: [Client] = clients.filter { $0.handshakeDone }
        guard !handshaked.isEmpty, let snap = snapshotCell.read() else { return }
        broadcast(snap: snap, handshaked: handshaked)
    }

    private func flushPendingWrites() {
        for client in Array(clients) where client.hasPending && !client.flush() {
            sendFailures += 1
            ControlLog.logger.info("client dropped while flushing fd=\(client.fd, privacy: .public) errno=\(client.lastSendError ?? 0, privacy: .public)")
            removeClient(client)
        }
    }

    private func evictStaleHandshakes() {
        let now = ContinuousClock.now
        for client in Array(clients) where !client.handshakeDone && now - client.acceptedAt > handshakeTimeout {
            handshakeTimeouts += 1
            ControlLog.logger.info("client dropped without handshake fd=\(client.fd, privacy: .public)")
            removeClient(client)
        }
    }

    // MARK: - Snapshot diffing + broadcast (bgQueue only)

    private func broadcast(snap: ControlSnapshot, handshaked: [Client]) {
        let prev = lastSnapshot
        let changed = prev != snap
        let newcomers = handshaked.contains { $0.needsInitialState }
        guard changed || newcomers else { return }
        lastSnapshot = snap

        guard let state = encode(stateFrame(snap)) else { return }
        var frames: [Data] = []
        var stateInFrames = false
        if changed {
            let (deltas, added) = deltaFrames(prev: prev, snap: snap)
            if added {
                frames.append(state)
                stateInFrames = true
            }
            if let meter = encode(meterFrame(snap)) { frames.append(meter) }
            frames += deltas.compactMap(encode)
        }

        var dead: [Client] = []
        var slow: [Client] = []
        for client in handshaked {
            var alive = true
            if client.needsInitialState {
                client.needsInitialState = false
                if !stateInFrames { alive = deliver(state, to: client) }
            }
            for frame in frames where alive { alive = deliver(frame, to: client) }
            if !alive {
                dead.append(client)
            } else if client.consecutiveDrops >= maxConsecutiveDrops {
                slow.append(client)
            }
        }
        sendFailures += dead.count
        for client in dead {
            if client.peerClosedDuringSend {
                ControlLog.logger.info("client disconnected during send fd=\(client.fd, privacy: .public)")
            } else {
                ControlLog.logger.error("client send failed fd=\(client.fd, privacy: .public) errno=\(client.lastSendError ?? 0, privacy: .public)")
            }
            removeClient(client)
        }
        slowClientEvictions += slow.count
        for client in slow {
            ControlLog.logger.warning("evicting client that stopped reading fd=\(client.fd, privacy: .public) drops=\(client.consecutiveDrops, privacy: .public)")
            removeClient(client)
        }
    }

    private func encode(_ obj: [String: Any]) -> Data? {
        do {
            return try encodeFrame(obj)
        } catch {
            ControlLog.logger.error("frame encode failed t=\(obj["t"] as? String ?? "?", privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Frame builders

    private func deltaFrames(prev: ControlSnapshot?, snap: ControlSnapshot) -> (frames: [[String: Any]], added: Bool) {
        var frames: [[String: Any]] = []
        var added = false
        guard let prev else { return (frames, added) }

        let prevIDs = Set(prev.mixes.map(\.id))
        let currIDs = Set(snap.mixes.map(\.id))
        for rid in prevIDs.subtracting(currIDs).sorted() {
            frames.append(["t": "removed", "mix": rid])
        }

        for m in snap.mixes {
            guard let p = prev.mixes.first(where: { $0.id == m.id }) else {
                added = true
                var a = mixFields(m)
                a["t"] = "added"
                a["mix"] = m.id
                frames.append(a)
                continue
            }
            if p.pos != m.pos || p.muted != m.muted || p.name != m.name || p.emoji != m.emoji {
                var d: [String: Any] = ["t": "delta", "mix": m.id,
                                        "pos": m.pos, "pct": m.pct, "muted": m.muted]
                if p.name  != m.name  { d["name"]  = m.name }
                if p.emoji != m.emoji { d["emoji"] = m.emoji }
                frames.append(d)
            }
        }

        let pm = prev.master
        if pm.pos != snap.master.pos || pm.muted != snap.master.muted {
            frames.append(["t": "masterDelta", "pos": snap.master.pos,
                           "pct": snap.master.pct, "muted": snap.master.muted])
        }
        return (frames, added)
    }

    private func meterFrame(_ snap: ControlSnapshot) -> [String: Any] {
        let mixes = snap.mixes.map { m -> [String: Any] in
            ["id": m.id,
             "level": Double(m.level),
             "levelLeft": Double(m.levelLeft),
             "levelRight": Double(m.levelRight)]
        }
        return ["t": "meter",
                "mixes": mixes,
                "master": ["level": Double(snap.master.level),
                           "levelLeft": Double(snap.master.levelLeft),
                           "levelRight": Double(snap.master.levelRight)]]
    }

    private func mixFields(_ m: MixSnapshot) -> [String: Any] {
        ["id": m.id, "name": m.name, "emoji": m.emoji,
         "pos": m.pos, "pct": m.pct, "muted": m.muted,
         "level": Double(m.level),
         "levelLeft": Double(m.levelLeft),
         "levelRight": Double(m.levelRight)]
    }

    private func stateFrame(_ snap: ControlSnapshot) -> [String: Any] {
        let master: [String: Any] = ["pos": snap.master.pos, "pct": snap.master.pct,
                                     "muted": snap.master.muted,
                                     "level": Double(snap.master.level),
                                     "levelLeft": Double(snap.master.levelLeft),
                                     "levelRight": Double(snap.master.levelRight),
                                     "icon": snap.master.icon]
        return ["t": "state", "mixes": snap.mixes.map(mixFields), "master": master]
    }
}
