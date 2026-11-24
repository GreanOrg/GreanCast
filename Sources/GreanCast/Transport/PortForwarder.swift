// PortForwarder.swift
// Listens on 127.0.0.1:<random port> and relays every accepted connection to a port on the
// iPhone through usbmuxd. HTTP clients then simply talk to http://127.0.0.1:<localPort>.
//
// Why: over USB the round trip is ~1 ms (vs ~15 ms on Wi‑Fi), it works without Wi‑Fi, and it
// needs no macOS "Local Network" permission. Few connections are open at once (HTTP keep-alive
// + one video stream), so a pair of threads per connection is simple and sufficient.

import Foundation

final class PortForwarder {
    let deviceID: Int
    let remotePort: UInt16
    private(set) var localPort: UInt16 = 0

    private var listenFD: Int32 = -1
    private var active = Set<Int32>()
    private let lock = NSLock()
    private var running = false

    init(deviceID: Int, remotePort: UInt16) {
        self.deviceID = deviceID
        self.remotePort = remotePort
    }

    deinit { stop() }

    /// Binds the local listener and starts accepting. Returns the local port.
    @discardableResult
    func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw USBMuxError.socket("listen socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                   // let the OS pick a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")       // loopback only: never exposed on the network
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw USBMuxError.socket("bind/listen: \(String(cString: strerror(errno)))")
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        localPort = UInt16(bigEndian: addr.sin_port)
        listenFD = fd
        running = true
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "GreanCast.forward.\(remotePort)"
        t.start()
        return localPort
    }

    func stop() {
        lock.lock()
        running = false
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
        for fd in active { shutdown(fd, SHUT_RDWR); close(fd) }
        active.removeAll()
        lock.unlock()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // listener closed by stop()
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread { [weak self] in self?.bridge(client) }.start()
        }
    }

    private func bridge(_ client: Int32) {
        let device: Int32
        do {
            device = try USBMux.connect(deviceID: deviceID, port: remotePort)
        } catch {
            // Expected while WebDriverAgent is starting: the port isn't open yet.
            Log.shared.info("USB: iPhone port \(remotePort) not reachable yet (\(error.localizedDescription))")
            close(client)
            return
        }
        lock.lock()
        guard running else { lock.unlock(); close(client); close(device); return }
        active.insert(client); active.insert(device)
        lock.unlock()

        let group = DispatchGroup()
        for (from, to) in [(client, device), (device, client)] {
            group.enter()
            Thread {
                Self.pump(from: from, to: to)
                shutdown(to, SHUT_WR)   // propagate EOF
                group.leave()
            }.start()
        }
        group.wait()
        lock.lock()
        active.remove(client); active.remove(device)
        lock.unlock()
        close(client); close(device)
    }

    private static func pump(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress!, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            var off = 0
            while off < n {
                let w = buffer.withUnsafeBytes { write(to, $0.baseAddress! + off, n - off) }
                if w < 0 && errno == EINTR { continue }
                if w <= 0 { return }
                off += w
            }
        }
    }
}
