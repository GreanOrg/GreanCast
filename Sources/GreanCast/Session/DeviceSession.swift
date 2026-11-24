// DeviceSession.swift
// Orchestrates a session: prerequisite checks → USB tunnel → (fetch / build / launch WDA if
// needed) → WDA session → video stream → lock monitoring. Also owns the ordered command queue
// fed by the mirror view (taps, gestures, typing, buttons).

import Foundation
import AppKit

@MainActor
final class DeviceSession: ObservableObject {

    enum Phase: Equatable {
        case checking
        case needsSetup                 // a prerequisite is missing: show the setup assistant
        case preparing(String)          // fetching / building WebDriverAgent
        case launching                  // waiting for WDA to start on the iPhone
        case connecting
        case waitingForUnlock           // XCTest refuses every action while the iPhone is locked
        case connected
        case failed(String)
    }

    // MARK: Published state

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var hint: String?
    @Published private(set) var xcodeVersion: String?
    @Published private(set) var teams: [DeveloperTeam] = []
    @Published private(set) var phones: [PhoneInfo] = []
    @Published private(set) var usbAttached = false
    @Published private(set) var image: NSImage?
    @Published private(set) var fps = 0
    @Published private(set) var lastLatencyMS: Int?
    @Published private(set) var pending = 0
    @Published private(set) var deviceSize: CGSize = .zero
    @Published private(set) var isLocked = false
    @Published private(set) var transportLabel = "—"

    // MARK: Settings (persisted)

    @Published var teamID: String { didSet { defaults.set(teamID, forKey: "teamID") } }
    @Published var udid: String { didSet { defaults.set(udid, forKey: "udid") } }
    @Published var useWiFi: Bool { didSet { defaults.set(useWiFi, forKey: "useWiFi") } }
    @Published var wifiURL: String { didSet { defaults.set(wifiURL, forKey: "wifiURL") } }
    @Published var videoScale: Double { didSet { defaults.set(videoScale, forKey: "videoScale") } }
    /// Prevents the iPhone from auto-locking while connected (on by default).
    @Published var keepAwake: Bool {
        didSet {
            defaults.set(keepAwake, forKey: "keepAwake")
            log.info("Keep iPhone awake: \(keepAwake ? "on" : "off")")
        }
    }

    var selectedPhone: PhoneInfo? { phones.first { $0.udid == udid } }
    var selectedTeam: DeveloperTeam? { teams.first { $0.id == teamID } }

    // MARK: Internals

    private let defaults = UserDefaults.standard
    private let log = Log.shared
    private let wda = WDAManager()
    private let stream = MJPEGStream()
    private var client: WDAClient?
    private var forwarders: [PortForwarder] = []
    private var chain: Task<Void, Never>?
    private var lockTimer: Timer?
    private var keepAwakeTimer: Timer?
    private var lastActivity = Date()
    private var fpsTimer: Timer?
    private var frameCount = 0
    private var typeBuffer = ""
    private var typeFlush: DispatchWorkItem?
    private var typingQueued = false
    private var scrollAccum = CGSize.zero
    private var scrollFlush: DispatchWorkItem?
    private var relaunchAttempts = 0

    init() {
        teamID = defaults.string(forKey: "teamID") ?? ""
        udid = defaults.string(forKey: "udid") ?? ""
        useWiFi = defaults.bool(forKey: "useWiFi")
        wifiURL = defaults.string(forKey: "wifiURL") ?? "http://192.168.0.10:8100"
        videoScale = defaults.object(forKey: "videoScale") as? Double ?? 50
        keepAwake = defaults.object(forKey: "keepAwake") as? Bool ?? true

        stream.onFrame = { [weak self] img in self?.received(img) }
        stream.onError = { [weak self] msg in self?.log.info("Video stream: \(msg) — reconnecting") }
        wda.onReady = { [weak self] in self?.log.info("WebDriverAgent reports ready") }
        wda.onHint = { [weak self] h in self?.hint = h }
        wda.onExit = { [weak self] code in self?.wdaExited(code) }
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fps = self.frameCount
                self.frameCount = 0
            }
        }
    }

    // MARK: - Lifecycle

    private var flow: Task<Void, Never>?

    /// Runs the checks and, if everything is in place, connects (building/launching WDA as needed).
    /// A new call cancels the flow in progress.
    func start() {
        flow?.cancel()
        flow = Task { await startFlow() }
    }

    func refreshChecks() async {
        xcodeVersion = await SystemChecks.xcodeVersion()
        teams = SystemChecks.teams()
        phones = await SystemChecks.phones()
        // Never pick a team on the user's behalf when there are several: signing creates an App
        // ID and registers the iPhone in that team (possibly a company account).
        if selectedTeam == nil, teams.count == 1 { teamID = teams[0].id }
        if selectedPhone == nil, let first = phones.first(where: { $0.transport == "wired" }) ?? phones.first { udid = first.udid }
        let usb = (try? USBMux.listDevices()) ?? []
        usbAttached = usb.contains { $0.udid == udid && $0.connectionType == "USB" }
    }

    /// True when every prerequisite of the setup assistant is satisfied.
    var prerequisitesMet: Bool {
        xcodeVersion != nil && selectedTeam != nil && (selectedPhone?.developerMode ?? false) && (usbAttached || useWiFi)
    }

    private func startFlow() async {
        disconnect()
        hint = nil
        phase = .checking
        await refreshChecks()
        guard prerequisitesMet else { phase = .needsSetup; return }

        // 1. Transport: USB tunnel (default) or Wi‑Fi URL.
        let base: URL, mjpeg: URL
        do { (base, mjpeg) = try makeTransport() } catch {
            phase = .failed("Transport: \(describe(error))"); return
        }

        // 2. Already running? (e.g. started by a previous GreanCast session)
        if await isReachable(base) {
            if await connect(base: base, mjpeg: mjpeg) != .needsRestart { return }
            // A runner that lost its XCTest authorization keeps answering /status but refuses
            // every action: restart it.
            log.info("WebDriverAgent lost its XCTest authorization — restarting it")
        }
        guard !Task.isCancelled else { return }

        // 3. Make sure WDA is built for this team, then (re)launch it.
        do {
            let run = try await ensureBuilt()
            guard !Task.isCancelled else { return }
            phase = .launching
            try wda.start(xctestrun: run, udid: udid)
        } catch {
            phase = .failed(describe(error)); return
        }
        // xcodebuild replaces any runner already on the device; wait for the new one.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for _ in 0..<120 {   // up to ~2 min (first launch installs the runner)
            guard !Task.isCancelled else { return }
            if await isReachable(base) { _ = await connect(base: base, mjpeg: mjpeg); return }
            if !wda.isRunning { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        phase = .failed(hint ?? "WebDriverAgent did not start. Check that the iPhone is unlocked and see the log.")
    }

    private func makeTransport() throws -> (URL, URL) {
        forwarders.forEach { $0.stop() }
        forwarders = []
        if usbAttached, let dev = try USBMux.listDevices().first(where: { $0.udid == udid && $0.connectionType == "USB" }) {
            let http = PortForwarder(deviceID: dev.deviceID, remotePort: WDAManager.wdaPort)
            let video = PortForwarder(deviceID: dev.deviceID, remotePort: WDAManager.mjpegPort)
            let hp = try http.start(), vp = try video.start()
            forwarders = [http, video]
            transportLabel = "USB"
            log.info("USB tunnel: 127.0.0.1:\(hp) → iPhone:8100, 127.0.0.1:\(vp) → iPhone:9100")
            return (URL(string: "http://127.0.0.1:\(hp)")!, URL(string: "http://127.0.0.1:\(vp)")!)
        }
        guard let url = URL(string: wifiURL), let host = url.host else { throw WDAError(message: "invalid Wi‑Fi URL") }
        transportLabel = "Wi‑Fi"
        log.info("Wi‑Fi transport: \(url.absoluteString) (unauthenticated — trusted networks only)")
        var c = URLComponents(); c.scheme = "http"; c.host = host; c.port = Int(WDAManager.mjpegPort)
        return (url, c.url!)
    }

    private func isReachable(_ base: URL) async -> Bool {
        (try? await WDAClient(baseURL: base).status())?["ready"] as? Bool ?? false
    }

    private func ensureBuilt() async throws -> URL {
        if let run = WDAManager.xctestrun(team: teamID) { return run }
        if !WDAManager.isSourcePresent {
            phase = .preparing("Downloading WebDriverAgent…")
            log.info("Fetching WebDriverAgent \(WDAManager.pinnedCommit.prefix(7))")
            try await WDAManager.fetchSource { [weak self] l in Task { @MainActor in self?.log.info("git: \(l)") } }
        }
        phase = .preparing("Building and signing WebDriverAgent for team \(teamID)… (1–3 min)")
        log.info("Building WebDriverAgent for team \(teamID)")
        return try await WDAManager.build(team: teamID, udid: udid) { _ in }
    }

    enum ConnectResult { case ok, failed, needsRestart }

    @discardableResult
    private func connect(base: URL, mjpeg: URL) async -> ConnectResult {
        phase = .connecting
        let c = WDAClient(baseURL: base)
        // A locked iPhone makes session creation fail ("Not authorized for performing UI testing
        // actions"): wait for the user to unlock it, then carry on automatically.
        if (try? await c.isLocked()) == true {
            phase = .waitingForUnlock
            log.info("iPhone is locked — waiting for it to be unlocked")
            while (try? await c.isLocked()) == true {
                guard phase == .waitingForUnlock, !Task.isCancelled else { return .failed }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            log.info("iPhone unlocked")
            phase = .connecting
        }
        do {
            try await c.createSession()
            try await c.applySettings(mjpegScale: Int(videoScale))
            deviceSize = try await c.windowSize()
            client = c
            stream.start(url: mjpeg)
            phase = .connected
            hint = nil
            relaunchAttempts = 0
            log.info("Connected via \(transportLabel) — \(Int(deviceSize.width))×\(Int(deviceSize.height)) pt")
            startLockMonitor()
            lastActivity = Date()
            startKeepAwake()
            return .ok
        } catch {
            let message = describe(error)
            if message.contains("Not authorized for performing UI testing") { return .needsRestart }
            phase = .failed("Could not open a WebDriverAgent session: \(message)")
            return .failed
        }
    }

    func disconnect() {
        stream.stop()
        lockTimer?.invalidate(); lockTimer = nil
        keepAwakeTimer?.invalidate(); keepAwakeTimer = nil
        chain?.cancel(); chain = nil
        client = nil
        image = nil
        isLocked = false
        pending = 0
        forwarders.forEach { $0.stop() }
        forwarders = []
    }

    /// Stops WDA on the iPhone and closes everything (app quit).
    func shutdown() {
        disconnect()
        wda.stop()
    }

    private func wdaExited(_ code: Int32) {
        log.info("WebDriverAgent runner exited (code \(code))")
        guard phase == .connected, relaunchAttempts < 3 else { return }
        relaunchAttempts += 1
        log.info("Restarting WebDriverAgent (attempt \(relaunchAttempts))")
        start()
    }

    // MARK: - Lock monitoring

    private func startLockMonitor() {
        lockTimer?.invalidate()
        lockTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let c = self.client else { return }
                if let locked = try? await c.isLocked(), locked != self.isLocked {
                    self.isLocked = locked
                    self.log.info(locked ? "iPhone locked" : "iPhone unlocked")
                }
            }
        }
    }

    func unlock() {
        run("unlock") { c in try await c.unlock() }
    }

    // MARK: - Keep awake

    /// Without user commands for `keepAwakeIdle` seconds, sends an invisible HID event so that
    /// iOS doesn't auto-lock (see `WDAClient.keepAlive`). Nothing is sent while locked.
    private static let keepAwakeIdle: TimeInterval = 20

    private func startKeepAwake() {
        keepAwakeTimer?.invalidate()
        keepAwakeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.keepAwakeTick() }
        }
    }

    private func keepAwakeTick() {
        guard keepAwake, phase == .connected, !isLocked, pending == 0,
              Date().timeIntervalSince(lastActivity) >= Self.keepAwakeIdle else { return }
        run("keep awake", silent: true) { c in try await c.keepAlive() }
    }

    /// Unlock before a session exists (waiting-for-unlock screen). Works without a passcode only.
    func wakeAndUnlock() {
        guard let base = forwarders.first.map({ URL(string: "http://127.0.0.1:\($0.localPort)")! })
                ?? URL(string: wifiURL) else { return }
        Task { try? await WDAClient(baseURL: base).unlock() }
    }

    // MARK: - Video

    private func received(_ img: NSImage) {
        frameCount += 1
        // Rotation: if the frame orientation no longer matches the known size, re-read it.
        if deviceSize != .zero, (img.size.width > img.size.height) != (deviceSize.width > deviceSize.height), let c = client {
            deviceSize = CGSize(width: deviceSize.height, height: deviceSize.width)
            Task { if let s = try? await c.windowSize() { self.deviceSize = s } }
        }
        image = img
    }

    func applyVideoScale() {
        let s = Int(videoScale)
        run("video quality") { c in try await c.applySettings(mjpegScale: s) }
    }

    /// Copies the current frame to the clipboard.
    func copyScreenshot() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        log.info("Screenshot copied to the clipboard")
    }

    // MARK: - Command queue

    /// Runs commands strictly in order, one at a time, and records each one's latency.
    /// `silent` commands (keep-awake) don't show in the latency or queue counters.
    private func run(_ name: String, silent: Bool = false, _ op: @escaping (WDAClient) async throws -> Void) {
        guard let c = client, phase == .connected else { return }
        lastActivity = Date()
        if !silent { pending += 1 }
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            let t0 = Date()
            do {
                try await op(c)
                if !silent { self?.lastLatencyMS = Int(Date().timeIntervalSince(t0) * 1000) }
            } catch {
                self?.log.error("\(name): \(describe(error))")
            }
            if !silent { self?.pending -= 1 }
        }
    }

    private func toDevice(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * deviceSize.width, y: p.y * deviceSize.height)
    }
}

// MARK: - Input from the mirror view

extension DeviceSession: MirrorInputHandler {

    func tap(at p: CGPoint) {
        flushTyping()
        let d = toDevice(p)
        run("tap") { c in try await c.tap(d) }
    }

    func longPress(at p: CGPoint, ms: Int) {
        flushTyping()
        let d = toDevice(p)
        run("long press") { c in try await c.longPress(d, ms: min(ms, 3000)) }
    }

    func gesture(_ points: [(p: CGPoint, ms: Int)]) {
        flushTyping()
        let pts = points.map { WDAClient.GesturePoint(point: toDevice($0.p), delayMS: min($0.ms, 1000)) }
        run("drag") { c in try await c.perform(points: pts) }
    }

    /// Scrolling is accumulated for 120 ms and replayed as a drag from the screen centre.
    func scroll(dx: CGFloat, dy: CGFloat, precise: Bool) {
        let k: CGFloat = precise ? 1.0 : 12.0
        scrollAccum.width += dx * k
        scrollAccum.height += dy * k
        scrollFlush?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.sendScroll() }
        scrollFlush = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func sendScroll() {
        guard deviceSize != .zero else { return }
        let maxX = deviceSize.width * 0.4, maxY = deviceSize.height * 0.4
        let dx = min(max(scrollAccum.width, -maxX), maxX)
        let dy = min(max(scrollAccum.height, -maxY), maxY)
        scrollAccum = .zero
        guard abs(dx) > 2 || abs(dy) > 2 else { return }
        let c = CGPoint(x: deviceSize.width / 2, y: deviceSize.height / 2)
        let start = CGPoint(x: c.x - dx / 2, y: c.y - dy / 2)
        let end = CGPoint(x: c.x + dx / 2, y: c.y + dy / 2)
        run("scroll") { cl in
            try await cl.perform(points: [.init(point: start, delayMS: 0), .init(point: end, delayMS: 200)])
        }
    }

    /// Each typing request costs ~320 ms whatever its length, so one queued request takes the
    /// whole buffer when it runs: everything typed while waiting goes out in a single request.
    func typeText(_ s: String) {
        typeBuffer += s
        typeFlush?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flushTyping() }
        typeFlush = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: w)
    }

    private func flushTyping() {
        typeFlush?.cancel(); typeFlush = nil
        guard !typeBuffer.isEmpty, !typingQueued else { return }
        typingQueued = true
        run("typing") { [weak self] c in
            guard let self else { return }
            let text = await MainActor.run { () -> String in
                let t = self.typeBuffer
                self.typeBuffer = ""
                self.typingQueued = false
                return t
            }
            if !text.isEmpty { try await c.type(text) }
        }
    }

    func note(_ s: String) { log.info(s) }

    // MARK: Buttons

    func home() { flushTyping(); run("home") { c in try await c.home() } }
    func volume(up: Bool) { run("volume") { c in try await c.pressButton(up ? "volumeUp" : "volumeDown") } }
    func launchApp(_ bundleID: String) {
        let b = bundleID.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return }
        run("open \(b)") { c in try await c.launch(bundleID: b) }
    }

    /// App switcher: swipe up from the bottom edge with a pause mid-screen.
    func appSwitcher() {
        let w = deviceSize.width, h = deviceSize.height
        run("app switcher") { c in
            try await c.perform(points: [
                .init(point: CGPoint(x: w / 2, y: h - 2), delayMS: 0),
                .init(point: CGPoint(x: w / 2, y: h * 0.6), delayMS: 250),
                .init(point: CGPoint(x: w / 2, y: h * 0.58), delayMS: 600),
            ])
        }
    }

    /// Control Center: swipe down from the top-right corner.
    func controlCenter() {
        let w = deviceSize.width, h = deviceSize.height
        run("control center") { c in
            try await c.perform(points: [
                .init(point: CGPoint(x: w - 30, y: 2), delayMS: 0),
                .init(point: CGPoint(x: w - 30, y: h * 0.45), delayMS: 250),
            ])
        }
    }
}
