// Log.swift
// In-app log (shown in the inspector), mirrored to stdout and ~/Library/Logs/GreanCast.log.

import Foundation

final class Log: ObservableObject {
    static let shared = Log()

    struct Entry: Identifiable {
        let id: Int
        let date: Date
        let text: String
        let isError: Bool
    }

    @Published private(set) var entries: [Entry] = []

    let fileURL: URL
    private var nextID = 0
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("GreanCast.log")
        append("── GreanCast \(Bundle.main.shortVersion) started ──\n")
    }

    /// Thread-safe. UI updates are dispatched to the main thread.
    func info(_ text: String) { add(text, isError: false) }
    func error(_ text: String) { add(text, isError: true) }

    private func add(_ text: String, isError: Bool) {
        let date = Date()
        let line = "\(formatter.string(from: date)) \(isError ? "ERROR " : "")\(text)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        append(line)
        let push = { [self] in
            entries.append(Entry(id: nextID, date: date, text: text, isError: isError))
            nextID += 1
            if entries.count > 1000 { entries.removeFirst(entries.count - 1000) }
        }
        if Thread.isMainThread { push() } else { DispatchQueue.main.async(execute: push) }
    }

    func timestamp(_ e: Entry) -> String { formatter.string(from: e.date) }

    private func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: fileURL) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(s.utf8))
            try? h.close()
        }
    }
}

extension Bundle {
    var shortVersion: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev" }
}

/// Full description of an error, including domain and code.
func describe(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain {
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }
    return error.localizedDescription
}
