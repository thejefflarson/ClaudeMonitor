import Foundation

struct StopEvent {
    let sessionId: String
    let cwd: String?
}

struct CompactEvent {
    let sessionId: String
    let trigger: String   // "auto" or "manual"
}

struct NotificationEvent {
    let sessionId: String
    let notificationType: String  // "permission_prompt", "idle_prompt", "auth_success", etc.
    let message: String
}

/// Listens on a Unix domain socket for Claude Code hook payloads (Stop, PreCompact, Notification).
/// Hook command (auto-installed by HookInstaller): the ClaudeMonitorHook binary.
final class UnixSocketListener {
    static let socketPath = "/tmp/com.jeffl.es.ClaudeMonitor.sock"

    var onStop: ((StopEvent) -> Void)?
    var onCompact: ((CompactEvent) -> Void)?
    var onNotification: ((NotificationEvent) -> Void)?

    private var serverFd: Int32 = -1
    private var activeClientCount = 0
    private let queue = DispatchQueue(label: "com.jeffl.es.ClaudeMonitor.socket", qos: .utility)

    func start() {
        queue.async { [weak self] in self?.run() }
    }

    func stop() {
        let fd = serverFd
        serverFd = -1
        if fd >= 0 { close(fd) }
        Darwin.unlink(Self.socketPath)
    }

    // MARK: - Private

    private func run() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFd = fd

        // lstat before unlink to avoid TOCTOU symlink race: if the path is a symlink
        // we refuse to remove it, preventing an attacker from pre-creating a symlink. (insecure-local-storage)
        var existStat = stat()
        if lstat(Self.socketPath, &existStat) == 0 {
            guard (existStat.st_mode & S_IFMT) == S_IFSOCK else {
                close(fd); serverFd = -1; return
            }
            Darwin.unlink(Self.socketPath)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                let n = min(dst.count - 1, strlen(src))
                memcpy(dst.baseAddress!, src, n)
            }
        }

        let bound = withUnsafePointer(to: addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); serverFd = -1; return }
        // Restrict socket file to owner-only so other local users cannot connect. (insecure-local-storage)
        chmod(Self.socketPath, 0o600)
        listen(fd, 8)

        while serverFd >= 0 {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            // Peer-credential check — reject connections from processes owned by other users. (ipc-security)
            var peerUid: uid_t = ~0
            var peerGid: gid_t = ~0
            guard getpeereid(client, &peerUid, &peerGid) == 0, peerUid == getuid() else {
                close(client); continue
            }
            // Connection cap — combined with the per-client timeout this bounds queue occupancy. (insecure-design)
            guard activeClientCount < 8 else { close(client); continue }
            activeClientCount += 1
            handleClient(client)
            activeClientCount -= 1
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        // Per-connection receive timeout — prevents a slow/stalled client from blocking the
        // serial queue indefinitely. (insecure-design)
        var tv = timeval()
        tv.tv_sec = 10
        tv.tv_usec = 0
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let maxPayload = 1_048_576  // 1 MB cap — guards against OOM from oversized payloads. (model-dos)
        while data.count < maxPayload {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf.prefix(n))
        }
        guard data.count <= maxPayload else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = json["session_id"] as? String,
              UUID(uuidString: sessionId) != nil  // UUID format check — rejects spoofed/traversal IDs. (broken-access-control)
        else { return }

        // Route by hook_event_name when present, fall back to field-based detection.
        let eventName = json["hook_event_name"] as? String
        if eventName == "Notification", let rawMessage = json["message"] as? String {
            let message = String(rawMessage.prefix(4096))  // length cap prevents unbounded UI strings. (insecure-output-handling)
            let notifType = json["notification_type"] as? String ?? ""
            let event = NotificationEvent(sessionId: sessionId, notificationType: notifType, message: message)
            DispatchQueue.main.async { [weak self] in self?.onNotification?(event) }
        } else if eventName == "PreCompact" || json["trigger"] is String {
            let trigger = json["trigger"] as? String ?? ""
            let event = CompactEvent(sessionId: sessionId, trigger: trigger)
            DispatchQueue.main.async { [weak self] in self?.onCompact?(event) }
        } else {
            let event = StopEvent(sessionId: sessionId, cwd: json["cwd"] as? String)
            DispatchQueue.main.async { [weak self] in self?.onStop?(event) }
        }
    }
}
