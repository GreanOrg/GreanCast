// MCPSettings.swift
// Persisted settings of the built-in MCP server: where it listens and what a client may do.
// Everything is off until the user turns the server on in Settings › MCP.

import Foundation
import Security

/// One switch in Settings › MCP. A disabled permission hides its tools from `tools/list` and
/// refuses them in `tools/call`.
enum MCPPermission: String, CaseIterable, Identifiable {
    case screen, listApps, apps, typing, touch, buttons, clipboard, install

    var id: String { rawValue }

    var label: String {
        switch self {
        case .screen: return "See the screen"
        case .listApps: return "List installed apps"
        case .apps: return "Open and close apps, open links"
        case .typing: return "Type text"
        case .touch: return "Tap, swipe, answer alerts, rotate"
        case .buttons: return "Press buttons (Home, volume, lock…)"
        case .clipboard: return "Read and write the iPhone clipboard"
        case .install: return "Install apps from this Mac"
        }
    }

    /// The two permissions that reach beyond what is on screen are opt-in.
    var defaultValue: Bool { self != .clipboard && self != .install }
    var key: String { "mcpAllow." + rawValue }
}

@MainActor
final class MCPSettings: ObservableObject {
    static let defaultPort = 8765

    /// Accept clients on this Mac (127.0.0.1).
    @Published var local: Bool { didSet { defaults.set(local, forKey: "mcpLocal"); changed() } }
    /// Accept clients on the local network. They must use the URL that contains `token`.
    @Published var network: Bool { didSet { defaults.set(network, forKey: "mcpNetwork"); changed() } }
    @Published var port: Int { didSet { defaults.set(port, forKey: "mcpPort"); changed() } }
    @Published private(set) var token: String { didSet { defaults.set(token, forKey: "mcpToken") } }
    @Published private var allowed: [MCPPermission: Bool] = [:]

    /// Called after a change that requires the listener to restart.
    var onListenerChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    init() {
        local = defaults.bool(forKey: "mcpLocal")
        network = defaults.bool(forKey: "mcpNetwork")
        let p = defaults.integer(forKey: "mcpPort")
        port = (1024...65535).contains(p) ? p : Self.defaultPort
        token = defaults.string(forKey: "mcpToken") ?? ""
        for permission in MCPPermission.allCases {
            allowed[permission] = defaults.object(forKey: permission.key) as? Bool ?? permission.defaultValue
        }
        if token.isEmpty {
            token = Self.makeToken()
            defaults.set(token, forKey: "mcpToken")   // property observers don't run in init
        }
    }

    var isEnabled: Bool { local || network }
    var isPortValid: Bool { (1024...65535).contains(port) }

    func allows(_ permission: MCPPermission) -> Bool { allowed[permission] ?? permission.defaultValue }

    func set(_ permission: MCPPermission, _ value: Bool) {
        allowed[permission] = value
        defaults.set(value, forKey: permission.key)
    }

    /// Invalidates the network URL handed out so far.
    func regenerateToken() { token = Self.makeToken() }

    private func changed() { onListenerChange?() }

    /// 128 random bits, hex-encoded.
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
