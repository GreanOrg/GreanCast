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
    func call(_ method: String, _ path: String, body: Any? = nil, query: [String: String] = [:],
              timeout: TimeInterval = 30) async throws -> Any? {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            url = parts.url ?? url
        }
        var req = URLRequest(url: url)
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
    func sessionCall(_ method: String, _ path: String, body: Any? = nil, query: [String: String] = [:]) async throws -> Any? {
        if sessionID == nil { try await createSession() }
        do {
            return try await call(method, "session/\(sessionID!)/\(path)", body: body, query: query)
        } catch let e as WDAError where e.message.contains("invalid session id") {
            try await createSession()
            return try await call(method, "session/\(sessionID!)/\(path)", body: body, query: query)
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

    /// Two quick taps on the same point.
    func doubleTap(_ p: CGPoint) async throws {
        try await sessionCall("POST", "actions", body: ["actions": [[
            "type": "pointer", "id": "finger1",
            "parameters": ["pointerType": "touch"],
            "actions": [
                ["type": "pointerMove", "duration": 0, "x": Int(p.x), "y": Int(p.y)],
                ["type": "pointerDown", "button": 0],
                ["type": "pointerUp", "button": 0],
                ["type": "pause", "duration": 60],
                ["type": "pointerDown", "button": 0],
                ["type": "pointerUp", "button": 0],
            ],
        ]]])
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

    // MARK: - Keep awake

    /// Sends an empty HID keyboard event (page 0x07, usage 0x00, "no event indicated").
    /// iOS counts it as user activity and resets its Auto-Lock timer, with no visible effect:
    /// the on-screen keyboard stays up and nothing is typed. Measured on iOS 27.3: ~0.22 s.
    /// (Generic Desktop "System Wake Up" and Consumer usage 0 also reset the timer but block
    /// WebDriverAgent for ~5.2 s, so they are not used.)
    func keepAlive() async throws {
        try await sessionCall("POST", "wda/performIoHidEvent",
                              body: ["page": 0x07, "usage": 0x00, "duration": 0.005])
    }

    // MARK: - Screen lock

    /// True when the iPhone shows its lock screen (WDA can't type the passcode).
    func isLocked() async throws -> Bool {
        (try await call("GET", "wda/locked", timeout: 5) as? Bool) ?? false
    }

    /// Wakes the screen and swipes up. Only unlocks iPhones without a passcode.
    func unlock() async throws { try await call("POST", "wda/unlock") }

    func lock() async throws { try await call("POST", "wda/lock") }

    // MARK: - Screen content (used by the MCP server)

    /// Full-resolution PNG of the screen. Slower than the MJPEG stream; used when no recent
    /// frame is available.
    func screenshot() async throws -> Data {
        guard let b64 = try await call("GET", "screenshot") as? String,
              let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
            throw WDAError(message: "no screenshot in response")
        }
        return data
    }

    /// Accessibility tree of the frontmost app as nested dictionaries
    /// (type, label, name, value, rect, isEnabled, isVisible, children).
    func source() async throws -> [String: Any] {
        (try await sessionCall("GET", "source", query: ["format": "json"]) as? [String: Any]) ?? [:]
    }

    /// Finds the first element matching an NSPredicate and returns its WDA element ID.
    func findElement(predicate: String) async throws -> String {
        let v = try await sessionCall("POST", "element", body: ["using": "predicate string", "value": predicate]) as? [String: Any]
        guard let id = (v?["ELEMENT"] as? String) ?? (v?["element-6066-11e4-a52e-4f735466cecf"] as? String) else {
            throw WDAError(message: "no such element")
        }
        return id
    }

    func click(element id: String) async throws {
        try await sessionCall("POST", "element/\(id)/click")
    }

    // MARK: - Apps

    struct ActiveApp { let bundleID: String; let name: String }

    func activeApp() async throws -> ActiveApp {
        let v = try await call("GET", "wda/activeAppInfo", timeout: 10) as? [String: Any]
        return ActiveApp(bundleID: v?["bundleId"] as? String ?? "", name: v?["name"] as? String ?? "")
    }

    /// False when the app was not running.
    func terminate(bundleID: String) async throws -> Bool {
        (try await sessionCall("POST", "wda/apps/terminate", body: ["bundleId": bundleID]) as? Bool) ?? false
    }

    /// XCUIApplication.State: 0 unknown, 1 not running, 2 background (suspended), 3 background,
    /// 4 foreground.
    func appState(bundleID: String) async throws -> Int {
        (try await sessionCall("POST", "wda/apps/state", body: ["bundleId": bundleID]) as? NSNumber)?.intValue ?? 0
    }

    /// Opens a web link or a deep link with whichever app handles it.
    func open(url: String) async throws {
        try await sessionCall("POST", "url", body: ["url": url])
    }

    // MARK: - Alerts

    /// Text of the alert on screen, or nil when there is none.
    func alertText() async throws -> String? {
        do { return try await sessionCall("GET", "alert/text") as? String }
        catch let e as WDAError where e.message.contains("no such alert") { return nil }
    }

    func alertButtons() async throws -> [String] {
        (try await sessionCall("GET", "wda/alert/buttons") as? [String]) ?? []
    }

    /// Accepts or dismisses the alert, or presses the button called `button` when given.
    func answerAlert(accept: Bool, button: String?) async throws {
        var body: [String: Any] = [:]
        if let button { body["name"] = button }
        try await sessionCall("POST", accept ? "alert/accept" : "alert/dismiss", body: body)
    }

    // MARK: - Clipboard, orientation, keyboard, battery

    func pasteboard() async throws -> String {
        guard let b64 = try await call("POST", "wda/getPasteboard", body: ["contentType": "plaintext"]) as? String,
              let data = Data(base64Encoded: b64) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func setPasteboard(_ text: String) async throws {
        try await call("POST", "wda/setPasteboard",
                       body: ["contentType": "plaintext", "content": Data(text.utf8).base64EncodedString()])
    }

    /// "PORTRAIT", "LANDSCAPE", "UIA_DEVICE_ORIENTATION_LANDSCAPERIGHT" or
    /// "UIA_DEVICE_ORIENTATION_PORTRAIT_UPSIDEDOWN".
    func setOrientation(_ orientation: String) async throws {
        try await sessionCall("POST", "orientation", body: ["orientation": orientation])
    }

    func dismissKeyboard() async throws {
        try await sessionCall("POST", "wda/keyboard/dismiss")
    }

    /// Battery level (0…1) and UIDevice.BatteryState (1 unplugged, 2 charging, 3 full).
    func battery() async throws -> (level: Double, state: Int) {
        let v = try await sessionCall("GET", "wda/batteryInfo") as? [String: Any]
        return ((v?["level"] as? NSNumber)?.doubleValue ?? -1, (v?["state"] as? NSNumber)?.intValue ?? 0)
    }
}
