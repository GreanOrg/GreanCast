// WDAManager.swift
// Fetches WebDriverAgent at a pinned revision, builds/signs it with the user's Apple developer
// team, and runs it on the iPhone (`xcodebuild test-without-building`). The xcodebuild process
// must stay alive: when it exits, WDA stops on the iPhone.
//
// Everything lives in ~/Library/Application Support/GreanCast/.

import Foundation

final class WDAManager {
    /// appium/appium-ios revision tested with GreanCast (packages/webdriveragent).
    static let pinnedRepo = "https://github.com/appium/appium-ios.git"
    static let pinnedCommit = "103a4a50ad0338b6be97983f80720b500af925ec"
    static let wdaPort: UInt16 = 8100
    static let mjpegPort: UInt16 = 9100

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GreanCast", isDirectory: true)
    }
    static var sourceRoot: URL { supportDir.appendingPathComponent("appium-ios", isDirectory: true) }
    static var projectDir: URL { sourceRoot.appendingPathComponent("packages/webdriveragent", isDirectory: true) }
    static var projectFile: URL { projectDir.appendingPathComponent("WebDriverAgent.xcodeproj/project.pbxproj") }

    static func derivedData(team: String) -> URL {
        supportDir.appendingPathComponent("build/\(team)", isDirectory: true)
    }

    /// Bundle IDs are global across Apple: make the runner's ID unique per team.
    static func runnerBundleID(team: String) -> String { "greancast.wda.\(team.lowercased())" }

    // MARK: - State queries

    static var isSourcePresent: Bool { FileManager.default.fileExists(atPath: projectFile.path) }

    /// The .xctestrun produced by a previous build for this team, if any.
    static func xctestrun(team: String) -> URL? {
        let products = derivedData(team: team).appendingPathComponent("Build/Products")
        let files = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "xctestrun" && $0.lastPathComponent.contains("iphoneos") }
            .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
            .first
    }

    // MARK: - Fetch

    /// Shallow, sparse fetch of packages/webdriveragent at the pinned commit (~5 MB).
    static func fetchSource(onLine: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: sourceRoot.path) { try fm.removeItem(at: sourceRoot) }
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let git = "/usr/bin/git"
        let steps: [[String]] = [
            ["init", "-q"],
            ["remote", "add", "origin", pinnedRepo],
            ["sparse-checkout", "set", "packages/webdriveragent"],
            ["fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", pinnedCommit],
            ["checkout", "-q", "FETCH_HEAD"],
        ]
        for args in steps {
            let r = await Shell.run(git, ["-C", sourceRoot.path] + args, onLine: onLine)
            guard r.ok else { throw WDAError(message: "git \(args.first ?? "") failed: \(r.output.suffix(400))") }
        }
        // Keep a pristine copy of the project file: the runner bundle ID is patched per team.
        try? fm.copyItem(at: projectFile, to: projectFile.appendingPathExtension("orig"))
    }

    // MARK: - Build

    /// Builds and signs WDA for `team`, registering `udid` in the team if needed.
    static func build(team: String, udid: String, onLine: @escaping (String) -> Void) async throws -> URL {
        try patchBundleID(team: team)
        let r = await Shell.xcrun([
            "xcodebuild", "build-for-testing",
            "-project", projectDir.appendingPathComponent("WebDriverAgent.xcodeproj").path,
            "-scheme", "WebDriverAgentRunner",
            "-destination", "id=\(udid)",
            "-derivedDataPath", derivedData(team: team).path,
            "DEVELOPMENT_TEAM=\(team)", "CODE_SIGN_STYLE=Automatic",
            "-allowProvisioningUpdates",
        ], onLine: onLine)
        guard r.ok, let run = xctestrun(team: team) else {
            throw WDAError(message: hint(for: r.output) ?? "WebDriverAgent build failed (see log)")
        }
        return run
    }

    private static func patchBundleID(team: String) throws {
        let orig = projectFile.appendingPathExtension("orig")
        var text = try String(contentsOf: FileManager.default.fileExists(atPath: orig.path) ? orig : projectFile, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "PRODUCT_BUNDLE_IDENTIFIER = com.facebook.WebDriverAgentRunner;",
            with: "PRODUCT_BUNDLE_IDENTIFIER = \(runnerBundleID(team: team));")
        try text.write(to: projectFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Run

    private var process: Process?
    var isRunning: Bool { process?.isRunning ?? false }
    /// Called (main thread) when WDA prints its server URL, i.e. it is ready.
    var onReady: (() -> Void)?
    /// Called (main thread) with a user-facing hint for known problems (locked, untrusted…).
    var onHint: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    func start(xctestrun: URL, udid: String) throws {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["xcodebuild", "test-without-building", "-xctestrun", xctestrun.path, "-destination", "id=\(udid)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var pending = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            pending += s
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl]); pending.removeSubrange(...nl)
                self?.handle(line)
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.onExit?(proc.terminationStatus) }
        }
        try p.run()
        process = p
        Log.shared.info("Launching WebDriverAgent on \(udid)…")
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func handle(_ line: String) {
        if line.contains("ServerURLHere->") {
            DispatchQueue.main.async { self.onReady?() }
        }
        if let h = Self.hint(for: line) {
            DispatchQueue.main.async { self.onHint?(h) }
        }
        if line.contains("error") || line.contains("Error") || line.contains("FAILED") {
            Log.shared.info("xcodebuild: \(line.trimmingCharacters(in: .whitespaces).prefix(300))")
        }
    }

    /// Turns known xcodebuild failures into actionable messages.
    static func hint(for output: String) -> String? {
        let rules: [(String, String)] = [
            ("Program License Agreement", "Apple requires you to accept the latest Program License Agreement: sign in at developer.apple.com/account with this team and accept it."),
            ("Unlock", "Unlock your iPhone — Xcode can't start WebDriverAgent while it is locked."),
            ("not been explicitly trusted", "On the iPhone, trust the developer certificate: Settings › General › VPN & Device Management."),
            ("Untrusted Developer", "On the iPhone, trust the developer certificate: Settings › General › VPN & Device Management."),
            ("Developer Mode", "Enable Developer Mode on the iPhone: Settings › Privacy & Security › Developer Mode."),
            ("No Accounts", "Add your Apple ID in Xcode › Settings › Accounts."),
            ("No profiles for", "Xcode couldn't create a provisioning profile for this team (see log)."),
            ("Maximum number of apps", "Free Apple accounts are limited to a few app IDs per week. Use a paid team or wait a few days."),
        ]
        return rules.first { output.contains($0.0) }?.1
    }
}

private extension URL {
    var modificationDate: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}
