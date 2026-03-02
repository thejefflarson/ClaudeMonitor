// ClaudeMonitorHook — Claude Code Stop hook helper.
// Claude Code pipes a JSON payload to stdin; we forward it to the app via Unix socket.
import Foundation

let socketPath = "/tmp/com.jeff.ClaudeMonitor.sock"

let data = FileHandle.standardInput.readDataToEndOfFile()
guard !data.isEmpty else { exit(0) }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
defer { close(fd) }

// 2-second send timeout so we never hang if the app is busy
var tv = timeval(tv_sec: 2, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
_ = socketPath.withCString { src in
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        memcpy(dst.baseAddress!, src, min(dst.count - 1, strlen(src)))
    }
}

let ok = withUnsafePointer(to: addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard ok == 0 else { exit(0) } // app not running — silent exit

data.withUnsafeBytes { ptr in
    _ = send(fd, ptr.baseAddress!, data.count, 0)
}
