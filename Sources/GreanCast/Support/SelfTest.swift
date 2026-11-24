// SelfTest.swift
// `GreanCast --selftest <file.png>`: waits for the connection, measures the video frame rate
// and the latency of a Home press, saves the current frame and quits. Used to check the whole
// chain (USB tunnel → WDA session → MJPEG → command queue) without clicking.

import AppKit

@MainActor
enum SelfTest {
    static func runIfRequested(_ session: DeviceSession) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let output = URL(fileURLWithPath: args[i + 1])
        let log = Log.shared
        Task {
            func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
            for _ in 0..<240 where session.phase != .connected {
                if case .failed(let m) = session.phase { log.error("selftest: \(m)"); NSApp.terminate(nil); return }
                if session.phase == .needsSetup { log.error("selftest: setup needed"); NSApp.terminate(nil); return }
                await wait(0.5)
            }
            await wait(3)
            log.info("selftest: transport=\(session.transportLabel) fps=\(session.fps) locked=\(session.isLocked) size=\(Int(session.deviceSize.width))×\(Int(session.deviceSize.height))")
            session.home()
            while session.pending > 0 { await wait(0.05) }
            log.info("selftest: Home latency \(session.lastLatencyMS ?? -1) ms")
            await wait(1)
            if let img = session.image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: output)
                log.info("selftest: frame \(Int(img.size.width))×\(Int(img.size.height)) saved to \(output.path)")
            }
            log.info("selftest: done")
            NSApp.terminate(nil)
        }
    }
}
