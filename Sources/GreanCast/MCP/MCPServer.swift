// MCPServer.swift
// The built-in MCP server: lets an AI client (Claude Code, Codex, Cursor, VS Code…) see and
// control the iPhone through GreanCast. Plain HTTP, no account and no login:
//   • this Mac:       http://127.0.0.1:<port>/mcp
//   • local network:  http://<mac-ip>:<port>/mcp/<token>   (off by default)
// This class owns the listener, decides who may connect, and hands MCP messages to the router.

import Foundation
import Darwin

@MainActor
final class MCPServer: ObservableObject {
    let settings = MCPSettings()

    @Published private(set) var state: HTTPServer.State = .stopped
    @Published private(set) var calls = 0
    @Published private(set) var lastClient: String?

    private var http: HTTPServer?
    private var router: MCPRouter?
    private var restart: DispatchWorkItem?
    private var running: (port: Int, loopbackOnly: Bool)?
    /// Set by the self-test: serve on 127.0.0.1 whatever the settings say.
    private var forced = false
    private let log = Log.shared

    private static let badPort = HTTPServer.State.failed("The port must be between 1024 and 65535")

    /// Call once at launch.
    func attach(_ session: DeviceSession) {
        guard router == nil else { return }
        let router = MCPRouter(settings: settings, runner: MCPToolRunner(session: session, settings: settings))
        router.onToolCall = { [weak self] name, client, failed, ms in
            guard let self else { return }
            self.calls += 1
            if let client { self.lastClient = client }
            self.log.info("MCP: \(name)\(client.map { " (\($0))" } ?? "") — \(failed ? "failed" : "ok"), \(ms) ms")
        }
        self.router = router
        let server = HTTPServer { [weak self] request, peer, reply in
            Task { @MainActor in
                guard let self else { reply(.empty(500)); return }
                reply(await self.respond(to: request, from: peer))
            }
        }
        server.onState = { [weak self] reported in
            guard let self else { return }
            // Stopped because of an unusable port: keep saying why.
            let s = reported == .stopped && self.settings.isEnabled && !self.settings.isPortValid ? Self.badPort : reported
            guard s != self.state else { return }
            self.state = s
            switch s {
            case .listening: self.log.info("MCP server listening on \(self.settings.network ? "all interfaces" : "127.0.0.1"), port \(self.settings.port)")
            case .failed(let m): self.log.error("MCP server: \(m)")
            case .stopped: self.log.info("MCP server stopped")
            }
        }
        server.onConnectionProblem = { message in Log.shared.error("MCP: \(message)") }
        http = server
        // The port field changes on every keystroke: restart once it settles.
        settings.onListenerChange = { [weak self] in self?.scheduleApply() }
        apply()
    }

    func stop() {
        restart?.cancel()
        running = nil
        http?.stop()
    }

    /// Self-test only: listen on 127.0.0.1:`port` without touching the saved settings.
    func startForSelfTest(port: Int) {
        forced = true
        running = (port, true)
        http?.start(port: UInt16(port), loopbackOnly: true)
    }

    private func scheduleApply() {
        restart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply() }
        restart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Starts, restarts or stops the listener so that it matches the settings.
    private func apply() {
        guard !forced, let http else { return }
        guard settings.isEnabled else {
            if running != nil { running = nil; http.stop() }
            return
        }
        guard settings.isPortValid else {
            running = nil
            http.stop()
            state = Self.badPort
            return
        }
        let wanted = (port: settings.port, loopbackOnly: !settings.network)
        if let running, running == wanted, state == .listening { return }
        running = wanted
        http.start(port: UInt16(wanted.port), loopbackOnly: wanted.loopbackOnly)
    }

    // MARK: - URLs shown in Settings

    var localURL: String { "http://127.0.0.1:\(settings.port)/mcp" }

    /// Nil when the Mac has no local network address.
    var networkURL: String? {
        Self.localIPv4().map { "http://\($0):\(settings.port)/mcp/\(settings.token)" }
    }

    /// First private IPv4 address of an active interface (Wi‑Fi or Ethernet).
    private static func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, address: String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if !address.hasPrefix("169.254.") { candidates.append((String(cString: p.pointee.ifa_name), address)) }
        }
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.address
    }

    // MARK: - Requests

    /// Access control, then MCP. Runs for every request.
    private func respond(to request: HTTPRequest, from peer: HTTPPeer) async -> HTTPResponse {
        guard let router else { return .empty(500) }
        let segments = request.path.split(separator: "/").map(String.init)

        // 1. Who is calling. This Mac needs "local"; another machine needs "network", an address
        //    on the local network and the token in the path.
        if peer.isLoopback {
            guard forced || settings.local else { return refuse(403, "The MCP server is not enabled for this Mac", peer) }
            guard segments == ["mcp"] || segments == ["mcp", settings.token] else { return .text(404, "Not found. The MCP endpoint is /mcp") }
        } else {
            guard !forced, settings.network, peer.isLocalNetwork else { return refuse(403, "Network access to the MCP server is not enabled", peer) }
            guard segments == ["mcp", settings.token] else { return refuse(404, "Not found", peer) }
        }

        // 2. DNS rebinding: a web page in a browser must not be able to reach the server.
        if let origin = request.header("Origin"), !Self.isLocalName(URLComponents(string: origin)?.host) {
            return refuse(403, "Origin not allowed", peer)
        }
        if let host = request.header("Host"), !Self.isAllowedHost(host) {
            return refuse(403, "Host not allowed", peer)
        }

        // 3. Streamable HTTP: POST only (no SSE stream to GET, no session to DELETE).
        guard request.method == "POST" else {
            return HTTPResponse(status: 405, headers: ["Allow": "POST", "Content-Type": "text/plain; charset=utf-8"],
                                body: Data("This MCP endpoint accepts POST only.\n".utf8))
        }
        return await router.handle(request)
    }

    private func refuse(_ status: Int, _ message: String, _ peer: HTTPPeer) -> HTTPResponse {
        log.info("MCP: refused \(peer.address) — \(message)")
        return .json(status, MCPRouter.error(id: nil, -32600, message))
    }

    private static func isLocalName(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Host header: an IP literal, localhost or a .local name — never an arbitrary domain.
    private static func isAllowedHost(_ value: String) -> Bool {
        var host = value.lowercased()
        if host.hasPrefix("[") {                       // [v6]:port
            return host.contains("]")
        }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
