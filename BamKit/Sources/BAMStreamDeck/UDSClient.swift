import AppKit
import BamControlKit
import BamCore
import Foundation

/// NDJSON client for BAM's `control.sock`; reconnects with backoff, launches BAM only on user input.
@MainActor
final class UDSClient {
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private(set) var readBuffer = Data()
    private(set) var connected = false
    private var retryCount = 0
    private var retryWork: DispatchWorkItem?
    private var launchAttempted = false

    /// Decoded NDJSON frame from BAM. Called on the main actor.
    var onFrame: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    private var socketPath: String { BamPaths.controlSocketURL().path }

    func connect() {
        retryWork?.cancel()
        retryWork = nil
        guard !connected else { return }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { scheduleRetry(); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                let n = min(strlen(cstr), maxLen - 1)
                memcpy(dest.baseAddress!, cstr, n)
            }
        }

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            Darwin.close(fd)
            scheduleRetry()
            return
        }

        self.fd = fd
        connected = true
        retryCount = 0
        launchAttempted = false
        Log.info("UDS connected")
        startReading()
        send(["t": "hello", "v": 1, "client": "streamdeck"])
    }

    /// Drop the backoff and try immediately (BAM just launched).
    func reconnectNow() {
        retryCount = 0
        connect()
    }

    /// Launch BAM at most once per disconnected period.
    func launchBAMIfNeeded() {
        guard !connected, !launchAttempted else { return }
        launchAttempted = true
        for id in ["me.harke.bam", "me.harke.bam.dev"] {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
                if let error { Log.error("launch BAM: \(error.localizedDescription)") }
            }
            Log.info("launching BAM (\(id))")
            return
        }
        Log.error("BAM app not found via NSWorkspace")
    }

    /// Send one NDJSON frame to BAM. No-op if disconnected.
    func send(_ obj: [String: Any]) { sendFrame(obj) }

    // MARK: - Read

    private func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        src.resume()
        readSource = src
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.recv(fd, &buf, buf.count, 0)
        if n <= 0 { handleDisconnect(); return }
        consume(Data(buf.prefix(n)))
    }

    /// Consume received bytes without requiring a live socket.
    func consume(_ bytes: Data) {
        readBuffer.append(bytes)

        while let idx = readBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(readBuffer[readBuffer.startIndex ..< idx])
            readBuffer.removeSubrange(readBuffer.startIndex...idx)
            if lineData.isEmpty { continue }
            do {
                let obj = try decodeFrame(lineData)
                Log.info("UDS frame: \(obj["t"] as? String ?? "?")")
                onFrame?(obj)
            } catch {
                Log.error("UDS decode: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Write

    private func sendFrame(_ obj: [String: Any]) {
        guard connected else { return }
        var line: Data
        do {
            line = try encodeFrame(obj)
        } catch {
            Log.error("UDS encode \(obj["t"] as? String ?? "?"): \(error.localizedDescription)")
            return
        }
        line.append(0x0A)
        let ok = line.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + sent, raw.count - sent, MSG_NOSIGNAL)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        if !ok { handleDisconnect() }
    }

    // MARK: - Lifecycle

    private func handleDisconnect() {
        guard fd >= 0 else { return }
        readSource?.cancel()
        readSource = nil
        Darwin.close(fd)
        fd = -1
        connected = false
        readBuffer.removeAll()
        Log.info("UDS disconnected; retrying")
        onDisconnect?()
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryCount += 1
        let delay = min(0.5 * pow(2, Double(min(retryCount, 5))), 10.0)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.connect() }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
