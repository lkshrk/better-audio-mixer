import BamCore
import Foundation
import os

// MARK: - Wire protocol version

private let kProtocolVersion = 1
private let kAppName = "BAM"
private let kBuildVersion = "1.0.0"

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
}

// MARK: - NDJSON framing helpers

public enum FrameError: Error { case invalidUTF8, malformedJSON }

/// Encode a JSON-serialisable dictionary to a single NDJSON line (no newline appended).
public func encodeFrame(_ obj: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: obj)
}

/// Decode one NDJSON line (must not contain a newline) into a dictionary.
public func decodeFrame(_ data: Data) throws -> [String: Any] {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FrameError.malformedJSON
    }
    return obj
}

// MARK: - Thread-safe snapshot cell

/// Lock-protected cell holding the latest ControlSnapshot. The @MainActor model
/// pushes into this cell; the bgQueue timer reads from it — no actor hop needed
/// on the hot read path.
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

/// One connected client. Lives entirely on the server's background DispatchQueue.
/// @unchecked Sendable is safe: all mutations occur exclusively on bgQueue.
final class Client: Hashable, @unchecked Sendable {
    let fd: Int32
    var handshakeDone = false
    /// True until the first full state snapshot has been sent to this client.
    var needsInitialState = false
    var clientName: String?
    var readBuffer = Data()
    var recvBuffer = [UInt8](repeating: 0, count: 4096)

    init(fd: Int32) { self.fd = fd }

    static func == (lhs: Client, rhs: Client) -> Bool { lhs.fd == rhs.fd }
    func hash(into hasher: inout Hasher) { hasher.combine(fd) }

    /// Write one NDJSON frame (dict + "\n"). Returns false on EPIPE / error.
    func send(_ obj: [String: Any]) -> Bool {
        guard let data = try? encodeFrame(obj) else { return true }
        return sendFrame(data)
    }

    /// Write a pre-encoded NDJSON frame (Data + "\n"). Returns false on EPIPE / error.
    /// Lets callers serialise off bgQueue and hand a Sendable `Data` across queues.
    func sendFrame(_ data: Data) -> Bool {
        var line = data
        line.append(0x0A) // '\n'
        return line.withUnsafeBytes { buf -> Bool in
            var sent = 0
            while sent < buf.count {
                let n = Darwin.send(fd, buf.baseAddress! + sent, buf.count - sent, MSG_NOSIGNAL)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    func close() { Darwin.close(fd) }
}

// MARK: - ControlServer

/// Unix-domain-socket server. One instance per app lifetime.
///
/// Isolation model:
/// - The listening socket + all client I/O runs on `bgQueue` (serial DispatchQueue).
/// - Snapshots are pushed into `snapshotCell` from @MainActor (by the mixer or a
///   periodic push task); the bgQueue timer reads the cell directly — no actor hop
///   on the hot read path.
/// - Mutations (cmd) still hop to @MainActor to call the MixerControl mutators.
/// - `Client` objects are created and touched only on bgQueue.
public final class ControlServer: @unchecked Sendable {

    // MARK: - Public interface

    public weak var mixer: (any MixerControl)?

    /// Override to use a custom socket path (e.g. unique per test).
    public var socketPath: String? = nil

    public init() {}

    /// Start listening. Safe to call multiple times (no-op if already running).
    public func start() {
        bgQueue.async { [weak self] in self?.listen() }
    }

    /// Start listening synchronously — blocks until the socket is bound.
    /// Use in setUp to guarantee the socket is ready before the test connects.
    public func startSync() {
        bgQueue.sync { self.listen() }
    }

    /// Stop the server and close all connections (async).
    public func stop() {
        bgQueue.async { [weak self] in self?.stopListening() }
    }

    /// Stop the server synchronously — blocks until the bgQueue has processed the stop.
    /// Use in tearDown to guarantee cleanup before the next test's setUp runs.
    public func stopSync() {
        bgQueue.sync { self.stopListening() }
    }

    /// Push a new snapshot. Call this from @MainActor whenever the model changes
    /// (and on the app's ~30fps router meter sampler). The server broadcasts it to clients.
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
                sendFailures: sendFailures
            )
        }
    }

    // MARK: - Internal state (bgQueue only, except snapshotCell)

    private let bgQueue = DispatchQueue(label: "me.harke.bam.controlserver", qos: .utility)
    private let snapshotCell = SnapshotCell()
    private var serverFD: Int32 = -1
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

    // MARK: - Socket path

    private var resolvedSocketPath: String {
        if let p = socketPath { return p }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("me.harke.bam")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("control.sock").path
    }

    // MARK: - Listen

    private func listen() {
        guard serverFD == -1 else {
            ControlLog.logger.debug("listen ignored; already running")
            return
        }

        let sockPath = resolvedSocketPath
        unlink(sockPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            ControlLog.logger.error("socket failed errno=\(errno, privacy: .public)")
            return
        }

        let oldMask = umask(0o177)
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
            return
        }

        serverFD = fd

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
    }

    // MARK: - Accept

    private func acceptClient() {
        let clientFD = Darwin.accept(serverFD, nil, nil)
        guard clientFD >= 0 else {
            ControlLog.logger.warning("accept failed errno=\(errno, privacy: .public)")
            return
        }
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
                ControlLog.logger.warning("client recv failed fd=\(client.fd, privacy: .public) errno=\(errno, privacy: .public)")
            } else {
                ControlLog.logger.info("client disconnected fd=\(client.fd, privacy: .public)")
            }
            removeClient(client)
            return
        }
        client.readBuffer.append(client.recvBuffer, count: n)
        processLines(client: client)
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

    // MARK: - Frame dispatch

    private func handleFrame(_ data: Data, client: Client) {
        guard let obj = try? decodeFrame(data), let t = obj["t"] as? String else {
            malformedFrames += 1
            ControlLog.logger.warning("dropping malformed frame fd=\(client.fd, privacy: .public) bytes=\(data.count, privacy: .public)")
            return
        }
        switch t {
        case "hello":   handleHello(obj, client: client)
        case "cmd":     guard client.handshakeDone else { return }; handleCmd(obj)
        case "listMixes": guard client.handshakeDone else { return }; handleListMixes(client: client)
        case "listOutputs": guard client.handshakeDone else { return }; handleListOutputs(client: client)
        case "setOutputDevice": guard client.handshakeDone else { return }; handleSetOutputDevice(obj, client: client)
        default:        break
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
                         "app": kAppName, "build": kBuildVersion])
        ControlLog.logger.notice("client handshaked fd=\(client.fd, privacy: .public) name=\(client.clientName ?? "unknown", privacy: .private)")
        // Full state is sent on the next timer tick which reads snapshotCell directly.
    }

    // MARK: - Command dispatch (mutates @MainActor model)

    private func handleCmd(_ obj: [String: Any]) {
        guard let op = obj["op"] as? String else { return }
        let mixID = obj["mix"]   as? String
        let pos   = obj["pos"]   as? Double
        let delta = obj["delta"] as? Double
        let muted = obj["muted"] as? Bool

        Task { @MainActor [weak self] in
            guard let self, let mixer = self.mixer else { return }
            switch op {
            case "setPos":        guard let id = mixID, let pos   else { return }; mixer.setPos(mixID: id, pos: pos)
            case "nudgePos":      guard let id = mixID, let delta else { return }; mixer.nudgePos(mixID: id, delta: delta)
            case "setMuted":      guard let id = mixID, let muted else { return }; mixer.setMuted(mixID: id, muted: muted)
            case "toggleMuted":   guard let id = mixID            else { return }; mixer.toggleMuted(mixID: id)
            case "setMasterPos":        guard let pos   else { return }; mixer.setMasterPos(pos: pos)
            case "nudgeMasterPos":      guard let delta else { return }; mixer.nudgeMasterPos(delta: delta)
            case "setMasterMuted":      guard let muted else { return }; mixer.setMasterMuted(muted: muted)
            default:
                ControlLog.logger.warning("unknown command op=\(op, privacy: .public)")
            }
        }
    }

    // MARK: - listMixes

    private func handleListMixes(client: Client) {
        Task { @MainActor [weak self] in
            guard let self, let mixer = self.mixer else { return }
            let list = mixer.listMixes()
            let mixes = list.map { m -> [String: Any] in
                ["id": m.id, "name": m.name, "emoji": m.emoji]
            }
            guard let frame = try? encodeFrame(["t": "mixes", "mixes": mixes]) else { return }
            self.bgQueue.async { [weak self] in
                guard self != nil else { return }
                _ = client.sendFrame(frame)
            }
        }
    }

    // MARK: - listOutputs

    private func handleListOutputs(client: Client) {
        Task { @MainActor [weak self] in
            guard let self, let mixer = self.mixer else { return }
            let list = mixer.listOutputs()
            let outputs = list.map { o -> [String: Any] in
                ["uid": o.uid, "name": o.name, "active": o.active, "icon": o.icon]
            }
            guard let frame = try? encodeFrame(["t": "outputs", "outputs": outputs]) else { return }
            self.bgQueue.async { [weak self] in
                guard self != nil else { return }
                _ = client.sendFrame(frame)
            }
        }
    }

    // MARK: - setOutputDevice

    private func handleSetOutputDevice(_ obj: [String: Any], client: Client) {
        guard let uid = obj["uid"] as? String else { return }
        Task { @MainActor [weak self] in
            guard let self, let mixer = self.mixer else { return }
            let ok = mixer.setOutputDevice(uid: uid)
            self.bgQueue.async { [weak self] in
                guard self != nil else { return }
                if ok {
                    _ = client.send(["t": "outputs-ack", "uid": uid])
                } else {
                    ControlLog.logger.warning("unsupported output uid=\(uid, privacy: .private)")
                    _ = client.send(["t": "error", "code": "unsupported", "op": "setOutputDevice"])
                }
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
        let handshaked: [Client] = clients.filter { $0.handshakeDone }
        guard !handshaked.isEmpty else { return }
        guard let snap = snapshotCell.read() else { return }
        broadcastDiff(snap: snap, handshaked: handshaked)
    }

    // MARK: - Snapshot diffing + broadcast (bgQueue only)

    private func broadcastDiff(snap: ControlSnapshot, handshaked: [Client]) {
        let prev = lastSnapshot

        // Meter frame — level-only, always sent (~30fps)
        let meterMixes = snap.mixes.map { m -> [String: Any] in
            ["id": m.id,
             "level": Double(m.level),
             "levelLeft": Double(m.levelLeft),
             "levelRight": Double(m.levelRight)]
        }
        let meterFrame: [String: Any] = [
            "t": "meter",
            "mixes": meterMixes,
            "master": [
                "level": Double(snap.master.level),
                "levelLeft": Double(snap.master.levelLeft),
                "levelRight": Double(snap.master.levelRight)
            ]
        ]

        // Delta frames — pos/mute changes only, event-driven
        var deltaFrames: [[String: Any]] = []

        if let prev {
            let prevIDs = Set(prev.mixes.map(\.id))
            let currIDs = Set(snap.mixes.map(\.id))
            for rid in prevIDs.subtracting(currIDs) {
                deltaFrames.append(["t": "removed", "mix": rid])
            }
        }

        for m in snap.mixes {
            if let p = prev?.mixes.first(where: { $0.id == m.id }) {
                if p.pos != m.pos || p.muted != m.muted || p.name != m.name || p.emoji != m.emoji {
                    var d: [String: Any] = ["t": "delta", "mix": m.id,
                                            "pos": m.pos, "pct": m.pct, "muted": m.muted]
                    if p.name  != m.name  { d["name"]  = m.name }
                    if p.emoji != m.emoji { d["emoji"] = m.emoji }
                    deltaFrames.append(d)
                }
            }
        }

        // Master pos/mute diff — same event-driven shape as a mix delta, so a
        // remote (Stream Deck) that changed the master sees its tile update.
        if let pm = prev?.master, pm.pos != snap.master.pos || pm.muted != snap.master.muted {
            deltaFrames.append(["t": "masterDelta", "pos": snap.master.pos,
                                "pct": snap.master.pct, "muted": snap.master.muted])
        }

        lastSnapshot = snap

        var dead: [Client] = []
        for client in handshaked {
            var alive = true
            if client.needsInitialState {
                client.needsInitialState = false
                alive = client.send(stateFrame(snap))
            }
            if alive { alive = client.send(meterFrame) }
            for df in deltaFrames where alive { alive = client.send(df) }
            if !alive { dead.append(client) }
        }
        if !dead.isEmpty {
            sendFailures += dead.count
            ControlLog.logger.warning("removing dead clients after send failures count=\(dead.count, privacy: .public)")
        }
        for client in dead { removeClient(client) }
    }

    // MARK: - Frame builders

    private func stateFrame(_ snap: ControlSnapshot) -> [String: Any] {
        let mixes = snap.mixes.map { m -> [String: Any] in
            ["id": m.id, "name": m.name, "emoji": m.emoji,
             "pos": m.pos, "pct": m.pct, "muted": m.muted,
             "level": Double(m.level),
             "levelLeft": Double(m.levelLeft),
             "levelRight": Double(m.levelRight)]
        }
        let master: [String: Any] = ["pos": snap.master.pos, "pct": snap.master.pct,
                                     "muted": snap.master.muted,
                                     "level": Double(snap.master.level),
                                     "levelLeft": Double(snap.master.levelLeft),
                                     "levelRight": Double(snap.master.levelRight),
                                     "icon": snap.master.icon]
        return ["t": "state", "mixes": mixes, "master": master]
    }
}
