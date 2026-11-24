// USBMux.swift
// Minimal client for usbmuxd, the macOS daemon that multiplexes TCP connections to iOS
// devices over USB (/var/run/usbmuxd). Same protocol as libimobiledevice's `iproxy`.
//
// Message = 16-byte little-endian header (length, version=1, type=8 "plist", tag) + XML plist.
// After a successful "Connect", the socket becomes a raw TCP tunnel to the device port.

import Foundation

struct USBDevice: Hashable {
    let deviceID: Int
    let udid: String
    let connectionType: String   // "USB" or "Network"
}

enum USBMuxError: LocalizedError {
    case socket(String)
    case protocolError(String)
    case connectRefused(port: UInt16, code: Int)

    var errorDescription: String? {
        switch self {
        case .socket(let s): return "usbmuxd socket: \(s)"
        case .protocolError(let s): return "usbmuxd protocol: \(s)"
        case .connectRefused(let port, let code):
            return "the iPhone refused the connection on port \(port) (usbmuxd code \(code)) — is WebDriverAgent running?"
        }
    }
}

enum USBMux {
    static let socketPath = "/var/run/usbmuxd"

    /// Lists devices known to usbmuxd (both USB and Wi‑Fi paired).
    static func listDevices() throws -> [USBDevice] {
        let fd = try openSocket()
        defer { close(fd) }
        let reply = try exchange(fd, ["MessageType": "ListDevices"], tag: 1)
        guard let list = reply["DeviceList"] as? [[String: Any]] else {
            throw USBMuxError.protocolError("no DeviceList")
        }
        return list.compactMap { d in
            guard let id = d["DeviceID"] as? Int, let props = d["Properties"] as? [String: Any],
                  let udid = props["SerialNumber"] as? String else { return nil }
            return USBDevice(deviceID: id, udid: udid,
                             connectionType: props["ConnectionType"] as? String ?? "?")
        }
    }

    /// Opens a raw TCP tunnel to `port` on the device. Returns a connected file descriptor.
    static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        let fd = try openSocket()
        do {
            let reply = try exchange(fd, [
                "MessageType": "Connect",
                "DeviceID": deviceID,
                "PortNumber": Int(port.bigEndian),   // network byte order, as an integer
            ], tag: 2)
            let code = reply["Number"] as? Int ?? -1
            guard code == 0 else { throw USBMuxError.connectRefused(port: port, code: code) }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    // MARK: - Low level

    private static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw USBMuxError.socket(String(cString: strerror(errno))) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.prefix(raw.count - 1).enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw USBMuxError.socket(msg)
        }
        return fd
    }

    private static func exchange(_ fd: Int32, _ message: [String: Any], tag: UInt32) throws -> [String: Any] {
        var msg = message
        msg["ClientVersionString"] = "GreanCast"
        msg["ProgName"] = "GreanCast"
        let body = try PropertyListSerialization.data(fromPropertyList: msg, format: .xml, options: 0)
        var header = Data()
        for v in [UInt32(16 + body.count), 1, 8, tag] { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        try writeAll(fd, header + body)

        let h = try readExact(fd, 16)
        let length = h.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard length >= 16, length < 10_000_000 else { throw USBMuxError.protocolError("bad length \(length)") }
        let reply = try readExact(fd, Int(length) - 16)
        guard let plist = try PropertyListSerialization.propertyList(from: reply, format: nil) as? [String: Any] else {
            throw USBMuxError.protocolError("bad plist")
        }
        return plist
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    throw USBMuxError.socket("write: \(String(cString: strerror(errno)))")
                }
                off += n
            }
        }
    }

    private static func readExact(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var off = 0
        try data.withUnsafeMutableBytes { raw in
            while off < count {
                let n = Darwin.read(fd, raw.baseAddress! + off, count - off)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    throw USBMuxError.socket("read: \(n == 0 ? "closed" : String(cString: strerror(errno)))")
                }
                off += n
            }
        }
        return data
    }
}
