// Shell.swift
// Runs command-line tools (xcrun, git, xcodebuild) without blocking the UI.

import Foundation

enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    /// Runs a tool to completion and returns its combined stdout/stderr.
    /// `onLine` receives each output line as it arrives (on a background thread).
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil,
                    onLine: ((String) -> Void)? = nil) async -> Result {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let buffer = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                buffer.append(s).forEach { onLine?($0) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                _ = buffer.append(String(data: rest, encoding: .utf8) ?? "")
                cont.resume(returning: Result(status: proc.terminationStatus, output: buffer.text))
            }
            do { try p.run() } catch {
                cont.resume(returning: Result(status: -1, output: "\(error)"))
            }
        }
    }

    /// Thread-safe accumulator: the pipe handler and the termination handler run on different threads.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var all = ""
        private var pending = ""

        /// Appends a chunk and returns the complete lines it finished.
        func append(_ s: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            all += s
            pending += s
            var lines: [String] = []
            while let nl = pending.firstIndex(of: "\n") {
                lines.append(String(pending[..<nl]))
                pending.removeSubrange(...nl)
            }
            return lines
        }

        var text: String { lock.lock(); defer { lock.unlock() }; return all }
    }

    static func xcrun(_ args: [String], onLine: ((String) -> Void)? = nil) async -> Result {
        await run("/usr/bin/xcrun", args, onLine: onLine)
    }
}
