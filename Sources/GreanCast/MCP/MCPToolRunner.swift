// MCPToolRunner.swift
// Executes MCP tool calls against the device session. Commands go through the session's ordered
// queue, so they interleave cleanly with what the user does in the mirror window.

import Foundation
import CoreGraphics

/// What a tool returns: MCP content blocks, and whether the call failed.
struct MCPToolResult {
    var content: [[String: Any]]
    var isError = false

    static func text(_ s: String) -> MCPToolResult { MCPToolResult(content: [["type": "text", "text": s]]) }
    static func error(_ s: String) -> MCPToolResult { MCPToolResult(content: [["type": "text", "text": s]], isError: true) }
}

@MainActor
final class MCPToolRunner {
    private let session: DeviceSession
    private let settings: MCPSettings
    private var appsCache: (udid: String, date: Date, apps: [InstalledApp])?

    init(session: DeviceSession, settings: MCPSettings) {
        self.session = session
        self.settings = settings
    }

    /// A bad argument or a failed precondition, reported to the client as a tool error.
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func call(_ tool: MCPTool, arguments a: [String: Any]) async -> MCPToolResult {
        do {
            return try await run(tool.name, a)
        } catch {
            return .error(GreanCast.describe(error))
        }
    }

    // MARK: - Dispatch

    private func run(_ name: String, _ a: [String: Any]) async throws -> MCPToolResult {
        switch name {
        case "screenshot":
            return MCPToolResult(content: try await screenshotBlocks(after: nil))

        case "screenshot_with_metadata":
            let blocks = try await screenshotBlocks(after: nil)
            return MCPToolResult(content: blocks + [["type": "text", "text": try await metadata()]])

        case "describe_ui":
            let size = session.deviceSize
            let text = try await session.perform("describe UI") { c in
                MCPToolRunner.describeUI(tree: try await c.source(), deviceSize: size)
            }
            return .text(text)

        case "wait_for":
            let label = try string(a, "label")
            let predicate = Self.predicate(label: label, contains: a["match"] as? String == "contains")
            let timeout = Double(min(max(int(a, "timeout_ms") ?? 5000, 0), 15000)) / 1000
            let start = Date()
            while true {
                // One queue slot per attempt: the user's own commands are not held up meanwhile.
                let found = try await session.perform("wait for \(label)") { c -> Bool in
                    do { _ = try await c.findElement(predicate: predicate); return true }
                    catch let e as WDAError where e.message.contains("no such element") { return false }
                }
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                if found { return .text("\"\(label)\" is on screen (after \(elapsed) ms).") }
                if Date().timeIntervalSince(start) >= timeout { return .error("\"\(label)\" did not appear within \(elapsed) ms.") }
                try await Task.sleep(nanoseconds: 300_000_000)
            }

        case "list_apps":
            return .text(try await listApps(scope: a["scope"] as? String ?? "all", query: a["query"] as? String))

        case "app_state":
            let id = try string(a, "bundle_id")
            let state = try await session.perform("state of \(id)") { c in try await c.appState(bundleID: id) }
            let names = [1: "not running", 2: "running in the background (suspended)", 3: "running in the background", 4: "running in the foreground"]
            return .text("\(id): \(names[state] ?? "unknown (is it installed?)")")

        case "launch_app":
            let id = try string(a, "bundle_id")
            return try await act(a, "Opened \(id).") { try await $0.perform("open \(id)") { c in try await c.launch(bundleID: id) } }

        case "terminate_app":
            let id = try string(a, "bundle_id")
            var wasRunning = false
            return try await act(a, { wasRunning ? "Terminated \(id)." : "\(id) was not running." }) {
                wasRunning = try await $0.perform("terminate \(id)") { c in try await c.terminate(bundleID: id) }
            }

        case "open_url":
            let url = try string(a, "url")
            guard let scheme = URL(string: url)?.scheme, !scheme.isEmpty else { throw Failure(message: "`url` must include a scheme, e.g. https://example.com") }
            return try await act(a, "Opened \(url).") { try await $0.perform("open URL") { c in try await c.open(url: url) } }

        case "install_app":
            let path = (try string(a, "path") as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), ["app", "ipa"].contains((path as NSString).pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: path) else {
                throw Failure(message: "`path` must be the absolute path of an existing .app bundle or .ipa file on the Mac.")
            }
            guard let udid = session.connectedUDID else { throw Failure(message: session.notConnectedReason) }
            try await SystemChecks.installApp(udid: udid, path: path)
            appsCache = nil
            return .text("Installed \((path as NSString).lastPathComponent).")

        case "type_text":
            let text = try string(a, "text")
            return try await act(a, "Typed \(text.count) character\(text.count == 1 ? "" : "s").") {
                try await $0.perform("typing") { c in try await c.type(text) }
            }

        case "tap":
            let p = try point(a, "x", "y")
            let kind = a["kind"] as? String ?? "tap"
            let hold = min(max(int(a, "duration_ms") ?? 800, 100), 3000)
            guard ["tap", "double_tap", "long_press"].contains(kind) else { throw Failure(message: "`kind` must be tap, double_tap or long_press.") }
            return try await act(a, "Done: \(kind.replacingOccurrences(of: "_", with: " ")) at (\(Int(try number(a, "x"))), \(Int(try number(a, "y")))).") {
                try await $0.perform(kind) { c in
                    switch kind {
                    case "double_tap": try await c.doubleTap(p)
                    case "long_press": try await c.longPress(p, ms: hold)
                    default: try await c.tap(p)
                    }
                }
            }

        case "tap_element":
            let label = try string(a, "label")
            let predicate = Self.predicate(label: label, contains: a["match"] as? String == "contains")
            return try await act(a, "Tapped \"\(label)\".") {
                try await $0.perform("tap \(label)") { c in
                    do { try await c.click(element: try await c.findElement(predicate: predicate)) }
                    catch let e as WDAError where e.message.contains("no such element") {
                        throw Failure(message: "No element labelled \"\(label)\" is on screen. Use describe_ui to see the labels.")
                    }
                }
            }

        case "swipe":
            let from = try point(a, "x1", "y1"), to = try point(a, "x2", "y2")
            let ms = min(max(int(a, "duration_ms") ?? 300, 50), 3000)
            return try await act(a, "Swiped.") {
                try await $0.perform("swipe") { c in
                    try await c.perform(points: [.init(point: from, delayMS: 0), .init(point: to, delayMS: ms)])
                }
            }

        case "press_button":
            let button = try string(a, "button")
            let size = session.deviceSize
            let w = size.width, h = size.height
            guard ["home", "volume_up", "volume_down", "app_switcher", "control_center", "lock"].contains(button) else {
                throw Failure(message: "Unknown button \"\(button)\".")
            }
            return try await act(a, "Pressed \(button.replacingOccurrences(of: "_", with: " ")).", needsUnlocked: button != "lock") {
                try await $0.perform(button) { c in
                    switch button {
                    case "home": try await c.home()
                    case "volume_up": try await c.pressButton("volumeUp")
                    case "volume_down": try await c.pressButton("volumeDown")
                    case "lock": try await c.lock()
                    case "app_switcher":   // same gestures as the Device menu
                        try await c.perform(points: [.init(point: CGPoint(x: w / 2, y: h - 2), delayMS: 0),
                                                     .init(point: CGPoint(x: w / 2, y: h * 0.6), delayMS: 250),
                                                     .init(point: CGPoint(x: w / 2, y: h * 0.58), delayMS: 600)])
                    default:
                        try await c.perform(points: [.init(point: CGPoint(x: w - 30, y: 2), delayMS: 0),
                                                     .init(point: CGPoint(x: w - 30, y: h * 0.45), delayMS: 250)])
                    }
                }
            }

        case "get_alert":
            let text = try await session.perform("read alert") { c -> String in
                guard let text = try await c.alertText() else { return "" }
                let buttons = (try? await c.alertButtons()) ?? []
                return "Alert: \(text)\nButtons: \(buttons.map { "\"\($0)\"" }.joined(separator: ", "))"
            }
            return .text(text.isEmpty ? "No alert on screen." : text)

        case "accept_alert", "dismiss_alert":
            let accept = name == "accept_alert"
            let button = (a["button"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return try await act(a, button.map { "Pressed \"\($0)\"." } ?? (accept ? "Alert accepted." : "Alert dismissed.")) {
                try await $0.perform(name) { c in
                    do { try await c.answerAlert(accept: accept, button: button) }
                    catch let e as WDAError where e.message.contains("no such alert") { throw Failure(message: "No alert on screen.") }
                }
            }

        case "set_orientation":
            let o = try string(a, "orientation").lowercased()
            guard o == "portrait" || o == "landscape" else { throw Failure(message: "`orientation` must be portrait or landscape.") }
            return try await act(a, "Rotated to \(o).") {
                try await $0.perform("rotate") { c in try await c.setOrientation(o.uppercased()) }
            }

        case "dismiss_keyboard":
            return try await act(a, "Keyboard hidden.") {
                try await $0.perform("dismiss keyboard") { c in try await c.dismissKeyboard() }
            }

        case "get_clipboard":
            let text = try await session.perform("read clipboard") { c in try await c.pasteboard() }
            return .text(text.isEmpty ? "The clipboard has no text." : text)

        case "set_clipboard":
            let text = try string(a, "text")
            try await session.perform("write clipboard") { c in try await c.setPasteboard(text) }
            return .text("Copied \(text.count) character\(text.count == 1 ? "" : "s") to the iPhone clipboard.")

        default:
            throw Failure(message: "Unknown tool \(name).")
        }
    }

    // MARK: - Actions

    private func act(_ a: [String: Any], _ message: String, needsUnlocked: Bool = true,
                     _ op: (DeviceSession) async throws -> Void) async throws -> MCPToolResult {
        try await act(a, { message }, needsUnlocked: needsUnlocked, op)
    }

    /// Runs an action, then appends a screenshot of its result when the client asked for one.
    private func act(_ a: [String: Any], _ message: () -> String, needsUnlocked: Bool = true,
                     _ op: (DeviceSession) async throws -> Void) async throws -> MCPToolResult {
        if needsUnlocked, session.isLocked { throw Failure(message: "The iPhone is locked. Unlock it on the device.") }
        try await op(session)
        var result = MCPToolResult.text(message())
        guard a["screenshot"] as? Bool == true else { return result }
        guard settings.allows(.screen) else {
            result.content.append(["type": "text", "text": "No screenshot: \"\(MCPPermission.screen.label)\" is turned off in GreanCast."])
            return result
        }
        let done = Date()
        let settle = min(max(int(a, "settle_ms") ?? 500, 0), 5000)
        try await Task.sleep(nanoseconds: UInt64(settle) * 1_000_000)
        do {
            result.content += try await screenshotBlocks(after: done.addingTimeInterval(Double(settle) / 1000))
        } catch {
            result.content.append(["type": "text", "text": "The action succeeded but the screenshot failed: \(GreanCast.describe(error))"])
        }
        return result
    }

    // MARK: - Screenshots

    /// The screen as MCP content: the image, then a line stating the coordinate space.
    /// With `after`, waits (up to 1 s) for a video frame newer than that date.
    private func screenshotBlocks(after: Date?) async throws -> [[String: Any]] {
        guard session.phase == .connected else { throw Failure(message: session.notConnectedReason) }
        // A frame older than this means the video stream stalled: ask WDA for a fresh screenshot.
        let oldest = after ?? Date().addingTimeInterval(-1)
        let deadline = Date().addingTimeInterval(after == nil ? 0.25 : 1)
        while (session.lastFrameDate ?? .distantPast) < oldest, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let size = session.deviceSize
        var raw = session.lastJPEG
        if raw == nil || (session.lastFrameDate ?? .distantPast) < oldest {
            raw = try await session.perform("screenshot") { c in try await c.screenshot() }
        }
        guard size != .zero, let raw, let jpeg = MCPImage.jpeg(from: raw, deviceSize: size) else {
            throw Failure(message: "No screen image is available yet.")
        }
        let px = MCPImage.size(for: size)
        return [
            ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
            ["type": "text", "text": "Screenshot \(px.width)×\(px.height) px. Coordinates for tap and swipe are in pixels of this image, origin top-left."],
        ]
    }

    private func metadata() async throws -> String {
        let size = session.deviceSize
        let px = MCPImage.size(for: size)
        let phone = session.selectedPhone
        var info: [String: Any] = [
            "time": ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime]),
            "device_name": phone?.name ?? "iPhone",
            "ios_version": phone?.osVersion ?? "",
            "connection": session.transportLabel,
            "screen_points": ["width": Int(size.width), "height": Int(size.height)],
            "screenshot_pixels": ["width": px.width, "height": px.height],
            "orientation": size.width > size.height ? "landscape" : "portrait",
            "locked": session.isLocked,
            "video_fps": session.fps,
        ]
        // One queue slot for the three device queries; each is optional.
        let extra = try await session.perform("metadata") { c -> Data in
            var d: [String: Any] = [:]
            if let app = try? await c.activeApp() {
                d["foreground_app"] = ["bundle_id": app.bundleID, "name": app.name]
            }
            if let v = try? await c.call("GET", "wda/device/info", timeout: 10) as? [String: Any] {
                for (key, name) in [("model", "model"), ("timeZone", "time_zone"), ("currentLocale", "locale"),
                                    ("userInterfaceStyle", "appearance")] {
                    if let value = v[key] as? String { d[name] = value }
                }
            }
            if let b = try? await c.battery(), b.level >= 0 {
                d["battery"] = ["percent": Int((b.level * 100).rounded()),
                                "state": [1: "unplugged", 2: "charging", 3: "full"][b.state] ?? "unknown"] as [String: Any]
            }
            return (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{}".utf8)
        }
        if let d = try? JSONSerialization.jsonObject(with: extra) as? [String: Any] { info.merge(d) { _, new in new } }
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Apps

    private func listApps(scope: String, query: String?) async throws -> String {
        guard let udid = session.connectedUDID else { throw Failure(message: session.notConnectedReason) }
        let apps: [InstalledApp]
        if let cache = appsCache, cache.udid == udid, Date().timeIntervalSince(cache.date) < 60 {
            apps = cache.apps
        } else {
            apps = try await SystemChecks.installedApps(udid: udid)
            appsCache = (udid, Date(), apps)
        }
        let q = query?.lowercased() ?? ""
        let shown = apps.filter { app in
            (scope == "all" || (scope == "system") == app.isSystem)
                && (q.isEmpty || app.name.lowercased().contains(q) || app.bundleID.lowercased().contains(q))
        }
        guard !shown.isEmpty else { return "No matching app." }
        return "\(shown.count) app\(shown.count == 1 ? "" : "s") (name — bundle ID — version):\n"
            + shown.map { "\($0.name) — \($0.bundleID) — \($0.version)" }.joined(separator: "\n")
    }

    // MARK: - Accessibility tree

    /// NSPredicate matching an element by label or accessibility identifier, case-insensitive.
    static func predicate(label: String, contains: Bool) -> String {
        let quoted = label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let op = contains ? "CONTAINS[c]" : "==[c]"
        return "(label \(op) '\(quoted)' OR name \(op) '\(quoted)') AND visible == 1"
    }

    /// Flattens WDA's tree into one line per visible, meaningful element, frames in image pixels.
    nonisolated static func describeUI(tree: [String: Any], deviceSize: CGSize) -> String {
        let scale = MCPImage.scale(for: deviceSize)
        let screen = CGRect(origin: .zero, size: deviceSize)
        let interactive: Set<String> = ["Button", "TextField", "SecureTextField", "SearchField", "TextView", "Switch",
                                        "Toggle", "Slider", "Link", "Cell", "Tab", "SegmentedControl", "Picker",
                                        "PickerWheel", "Stepper", "Icon", "MenuItem", "CheckBox", "RadioButton"]
        var lines: [String] = []
        var keys = 0
        var truncated = false

        func flag(_ v: Any?) -> Bool? {
            if let b = v as? Bool { return b }
            if let s = v as? String { return s == "1" || s.lowercased() == "true" }
            return (v as? NSNumber)?.boolValue
        }

        func visit(_ node: [String: Any]) {
            let type = node["type"] as? String ?? "Other"
            let r = node["rect"] as? [String: Any] ?? [:]
            func n(_ k: String) -> CGFloat { CGFloat((r[k] as? NSNumber)?.doubleValue ?? 0) }
            let rect = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
            let label = (node["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (node["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let value = (node["value"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let visible = flag(node["isVisible"]) ?? true
            let onScreen = rect.width > 0 && rect.height > 0 && rect.intersects(screen)

            if type == "Key" {
                keys += 1
            } else if visible, onScreen, type != "Application", type != "Window",
                      label != nil || value != nil || interactive.contains(type) {
                if lines.count >= 300 {
                    truncated = true
                } else {
                    var line = type
                    if let label { line += " \"\(label.replacingOccurrences(of: "\n", with: " "))\"" }
                    if let value, value != label { line += " value=\"\(value.replacingOccurrences(of: "\n", with: " "))\"" }
                    if flag(node["isEnabled"]) == false { line += " (disabled)" }
                    line += " [\(Int(rect.minX * scale)), \(Int(rect.minY * scale)), \(Int(rect.width * scale)), \(Int(rect.height * scale))]"
                    lines.append(line)
                }
            }
            for child in node["children"] as? [[String: Any]] ?? [] { visit(child) }
        }

        visit(tree)
        var out = "Elements on screen, as: Type \"label\" [x, y, width, height] in screenshot pixels. Tap the centre of a frame.\n"
        out += lines.isEmpty ? "(no labelled element)" : lines.joined(separator: "\n")
        if keys > 0 { out += "\nThe on-screen keyboard is visible (\(keys) keys not listed)." }
        if truncated { out += "\n(list truncated at 300 elements)" }
        return out
    }

    // MARK: - Arguments

    private func string(_ a: [String: Any], _ key: String) throws -> String {
        guard let s = a[key] as? String, !s.isEmpty else { throw Failure(message: "Missing argument `\(key)` (string).") }
        return s
    }

    private func number(_ a: [String: Any], _ key: String) throws -> Double {
        // JSON booleans are NSNumber too: refuse them.
        guard let n = a[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw Failure(message: "Missing argument `\(key)` (number).") }
        return n.doubleValue
    }

    private func int(_ a: [String: Any], _ key: String) -> Int? { (a[key] as? NSNumber)?.intValue }

    /// Converts a point in screenshot pixels to iOS points, refusing points outside the image.
    private func point(_ a: [String: Any], _ xKey: String, _ yKey: String) throws -> CGPoint {
        let x = try number(a, xKey), y = try number(a, yKey)
        let size = session.deviceSize
        guard size != .zero else { throw Failure(message: session.notConnectedReason) }
        let px = MCPImage.size(for: size)
        guard x >= 0, y >= 0, x <= Double(px.width), y <= Double(px.height) else {
            throw Failure(message: "(\(Int(x)), \(Int(y))) is outside the screen. The screenshot is \(px.width)×\(px.height) px.")
        }
        return MCPImage.point(x: x, y: y, deviceSize: size)
    }
}
