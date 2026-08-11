import Foundation

/// A native client for one zmx session, speaking the socket protocol directly
/// instead of spawning `zmx attach`.
///
/// Two things fall out of not having a subprocess: closing a pane can't leak a
/// client (there's no child to outlive the surface — we send `.Detach` and
/// close the fd), and the terminal's bytes go straight to the daemon.
///
/// A client that never sends `.initialize` is a passive observer: the daemon
/// only marks a connection as a terminal client on `.Init`, so it receives
/// `.output` without triggering screen replay or being counted as an attach.
/// That's the mode a peek overlay or an attention watcher wants.
final class ZmxClient: @unchecked Sendable {
    enum ClientError: Error {
        case socketPathTooLong(String)
        case connectFailed(String, errno: Int32)
    }

    /// Called with terminal output. Delivered on `queue`, not the main thread.
    var onOutput: (@Sendable (Data) -> Void)?
    /// Called when the daemon closes the connection or the session dies.
    var onClose: (@Sendable () -> Void)?

    let sessionName: String

    private let queue = DispatchQueue(label: "zmxterm.client")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var decoder = ZmxFrameDecoder()
    private var lastSize: ZmxResize?
    private var attached = false

    init(sessionName: String) {
        self.sessionName = sessionName
        Self.track(self)
    }

    // MARK: - Live clients

    /// Every connected client, so the app can detach cleanly on the way out.
    /// A client that dies without detaching lingers on the daemon and keeps a
    /// vote on the session's size — the exact ghost that pinned a session to a
    /// closed pane's width when we still spawned `zmx attach`.
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var live: [WeakClient] = []

    private struct WeakClient { weak var client: ZmxClient? }

    private static func track(_ client: ZmxClient) {
        liveLock.lock()
        defer { liveLock.unlock() }
        live.removeAll { $0.client == nil }
        live.append(WeakClient(client: client))
    }

    static func detachAll() {
        liveLock.lock()
        let clients = live.compactMap(\.client)
        liveLock.unlock()
        for client in clients { client.detach() }
    }

    /// zmx keeps one socket per session, named exactly the session name, under
    /// a per-uid directory. `zmx version` reports it as `socket_dir`.
    static func socketDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["ZMX_SOCKET_DIR"] {
            return URL(fileURLWithPath: override)
        }
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: tmp).appendingPathComponent("zmx-\(getuid())")
    }

    static func liveSessionNames() -> [String] {
        let dir = socketDirectory()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries.filter { $0 != "logs" }.sorted()
    }

    /// Connect and attach as a terminal client at `size`.
    func attach(size: ZmxResize) throws {
        try queue.sync {
            guard fd < 0 else { return }
            fd = try Self.connect(to: Self.socketDirectory().appendingPathComponent(sessionName))
            lastSize = size
            attached = true
            startReading()
            writeFrame(.initialize, size.payload)
        }
    }

    func send(_ tag: ZmxTag, _ payload: Data = Data()) {
        queue.async { [self] in
            guard fd >= 0 else { return }
            writeFrame(tag, payload)
        }
    }

    func resize(_ size: ZmxResize) {
        queue.async { [self] in
            guard fd >= 0, size != lastSize else { return }
            lastSize = size
            writeFrame(.resize, size.payload)
        }
    }

    /// Ask the daemon to send the screen again.
    ///
    /// `.Init` on an already-attached connection makes the daemon serialize its
    /// terminal state and send it back as `.Output` — the same restore a fresh
    /// attach gets. That is the only way to repaint a surface that was thrown
    /// away and rebuilt, because output arriving while it did not exist was
    /// dropped on the floor: the session had nowhere to write it.
    func repaint() {
        queue.async { [self] in
            guard fd >= 0, attached, let lastSize else { return }
            writeFrame(.initialize, lastSize.payload)
        }
    }

    /// Detach this client and drop the connection. The session keeps running.
    func detach() {
        queue.async { [self] in
            guard fd >= 0 else { return }
            if attached { writeFrame(.detach) }
            teardown()
        }
    }

    // MARK: - Socket

    private static func connect(to url: URL) throws -> Int32 {
        let path = url.path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw ClientError.socketPathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClientError.connectFailed(path, errno: errno) }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let saved = errno
            close(descriptor)
            throw ClientError.connectFailed(path, errno: saved)
        }
        return descriptor
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }

        if count <= 0 {
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            teardown()
            onClose?()
            return
        }

        decoder.feed(Data(chunk[0 ..< count]))
        while let message = decoder.next() {
            handle(message)
        }
    }

    private func handle(_ message: ZmxMessage) {
        switch message.tag {
        case .output:
            guard !message.payload.isEmpty else { return }
            onOutput?(message.payload)
        case .resize:
            // The daemon asks for our size, typically on being made leader.
            if let lastSize { writeFrame(.resize, lastSize.payload) }
        case .none:
            break // Unknown tag from a newer daemon: consumed and ignored.
        default:
            break
        }
    }

    private func writeFrame(_ tag: ZmxTag, _ payload: Data = Data()) {
        let frame = ZmxFrame.encode(tag, payload)
        frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    private func teardown() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 { close(fd) }
        fd = -1
        attached = false
    }
}
