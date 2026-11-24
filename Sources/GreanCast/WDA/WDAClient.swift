// WDAClient.swift
// Minimal HTTP client for WebDriverAgent (WDA), the XCUITest server running on the iPhone.
// All coordinates are iOS POINTS (e.g. 402 × 874 on iPhone 17 Pro), origin at the top left.
//
// Measured on iOS 27.3 (USB): tap ≈ 440 ms, typing ≈ 320 ms per request whatever its length,
// Home ≈ 50 ms. The time is spent in XCTest on the device, not in the transport.

import Foundation
import CoreGraphics

struct WDAError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class WDAClient {
    var baseURL: URL
    private(set) var sessionID: String?
    private let http: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 2   // keep-alive: reuse the TCP connection
        http = URLSession(configuration: cfg)
    }

    // MARK: - Transport

    /// Sends a request and returns the "value" field of the JSON response.
    @discardableResult
    func call(_ method: String, _ path: String, body: Any? = nil, timeout: TimeInterval = 30) async throws -> Any? {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if method == "POST" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{}".utf8)
        }
        let (data, _) = try await http.data(for: req)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let value = json?["value"]
        // WDA reports W3C errors in value.error / value.message.
        if let v = value as? [String: Any], let err = v["error"] as? String {
            throw WDAError(message: "\(err): \(v["message"] as? String ?? "")")
        }
        return value
    }

    /// Call within the current session; recreates the session once if it expired.
    @discardableResult
    func sessionCall(_ method: String, _ path: String, body: Any? = nil) async throws -> Any? {
        if sessionID == nil { try await createSession() }
        do {
            return try await call(method, "session/\(sessionID!)/\(path)", body: body)
        } catch let e as WDAError where e.message.contains("invalid session id") {
            try await createSession()
            return try await call(method, "session/\(sessionID!)/\(path)", body: body)
        }
    }

    // MARK: - Session and settings

    func status() async throws -> [String: Any] {
        (try await call("GET", "status", timeout: 5) as? [String: Any]) ?? [:]
    }

    func createSession() async throws {
        let url = baseURL.appendingPathComponent("session")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["capabilities": ["alwaysMatch": [:]]])
        let (data, _) = try await http.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let sid = (json?["sessionId"] as? String) ?? ((json?["value"] as? [String: Any])?["sessionId"] as? String) else {
            throw WDAError(message: "no sessionId in response")
        }
        sessionID = sid
        try await applySettings()
    }

    /// Responsiveness settings: without them WDA waits for the screen to be idle before every
    /// action (measured: 2.5 s per tap instead of ~0.45 s).
    func applySettings(mjpegScale: Int = 50, mjpegQuality: Int = 50, mjpegFPS: Int = 30) async throws {
        try await sessionCall("POST", "appium/settings", body: ["settings": [
            "waitForIdleTimeout": 0,
            "animationCoolOffTimeout": 0,
            // XCTest typing speed: ~320 ms per request instead of ~430 ms by default.
            "maxTypingFrequency": 600,
            "mjpegScalingFactor": mjpegScale,
            "mjpegServerScreenshotQuality": mjpegQuality,
            "mjpegServerFramerate": mjpegFPS,
        ]])
    }

    func windowSize() async throws -> CGSize {
        let v = try await sessionCall("GET", "window/size") as? [String: Any]
        let w = (v?["width"] as? NSNumber)?.doubleValue ?? 0
        let h = (v?["height"] as? NSNumber)?.doubleValue ?? 0
        return CGSize(width: w, height: h)
    }

    // MARK: - Gestures (W3C actions: the fastest path measured)

    /// A gesture point: position in iOS points and delay (ms) since the previous point.
    struct GesturePoint { let point: CGPoint; let delayMS: Int }

    func tap(_ p: CGPoint) async throws {
        // No pause between down and up: ~440 ms instead of ~580 ms with a 30 ms pause.
        try await perform(points: [GesturePoint(point: p, delayMS: 0)], holdMS: 0)
    }

    func longPress(_ p: CGPoint, ms: Int) async throws {
        try await perform(points: [GesturePoint(point: p, delayMS: 0)], holdMS: ms)
    }

    /// Replays a finger path: down on the first point, moves, up.
    func perform(points: [GesturePoint], holdMS: Int = 0) async throws {
        guard let first = points.first else { return }
        var actions: [[String: Any]] = [
            ["type": "pointerMove", "duration": 0, "x": Int(first.point.x), "y": Int(first.point.y)],
            ["type": "pointerDown", "button": 0],
        ]
        if holdMS > 0 { actions.append(["type": "pause", "duration": holdMS]) }
        for p in points.dropFirst() {
            actions.append(["type": "pointerMove", "duration": max(p.delayMS, 1),
                            "x": Int(p.point.x), "y": Int(p.point.y)])
        }
        actions.append(["type": "pointerUp", "button": 0])
        try await sessionCall("POST", "actions", body: ["actions": [[
            "type": "pointer", "id": "finger1",
            "parameters": ["pointerType": "touch"],
            "actions": actions,
        ]]])
    }

    // MARK: - Keyboard and buttons

    /// Types text into the focused element. "\u{8}" = backspace, "\n" = return.
    func type(_ text: String) async throws {
        try await sessionCall("POST", "wda/keys", body: ["value": [text]])
    }

    func home() async throws { try await call("POST", "wda/homescreen") }

    /// "volumeUp", "volumeDown" (and "home").
    func pressButton(_ name: String) async throws {
        try await sessionCall("POST", "wda/pressButton", body: ["name": name])
    }

    func launch(bundleID: String) async throws {
        try await sessionCall("POST", "wda/apps/launch", body: ["bundleId": bundleID])
    }

    // MARK: - Screen lock

    /// True when the iPhone shows its lock screen (WDA can't type the passcode).
    func isLocked() async throws -> Bool {
        (try await call("GET", "wda/locked", timeout: 5) as? Bool) ?? false
    }

    /// Wakes the screen and swipes up. Only unlocks iPhones without a passcode.
    func unlock() async throws { try await call("POST", "wda/unlock") }
}
