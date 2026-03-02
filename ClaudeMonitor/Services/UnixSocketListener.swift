import Foundation

struct StopEvent {
    let sessionId: String
    let cwd: String?
}

struct CompactEvent {
    let sessionId: String
    let trigger: String   // "auto" or "manual"
}

/// Listens on a Unix domain socket for Claude Code hook payloads (Stop and PreCompact).
/// Hook command (auto-installed by HookInstaller): the ClaudeMonitorHook binary.
final class UnixSocketListener {
    static let socketPath = "/tmp/com.jeffl.es.ClaudeMonitor.sock"

    var onStop: ((StopEvent) -> Void)?
    var onCompact: ((CompactEvent) -> Void)?

    private var serverFd: Int32 = -1
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

        Darwin.unlink(Self.socketPath)

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
        listen(fd, 8)

        while serverFd >= 0 {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            handleClient(client)
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf.prefix(n))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = json["session_id"] as? String
        else { return }

        // PreCompact payload has a "trigger" field; Stop payload has "stop_hook_active".
        if let trigger = json["trigger"] as? String {
            let event = CompactEvent(sessionId: sessionId, trigger: trigger)
            DispatchQueue.main.async { [weak self] in self?.onCompact?(event) }
        } else {
            let event = StopEvent(sessionId: sessionId, cwd: json["cwd"] as? String)
            DispatchQueue.main.async { [weak self] in self?.onStop?(event) }
        }
    }
}
