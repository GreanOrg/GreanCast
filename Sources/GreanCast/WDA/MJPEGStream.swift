// MJPEGStream.swift
// Reads WDA's MJPEG video stream (port 9100 by default): JPEG images separated by multipart
// headers. Frames are split on the JPEG start (FF D8) / end (FF D9) markers, which does not
// depend on the exact header format. Only the latest complete frame is decoded.

import Foundation
import AppKit

final class MJPEGStream: NSObject, URLSessionDataDelegate {
    /// Called on the main thread for each new frame, with the JPEG bytes it was decoded from.
    var onFrame: ((NSImage, Data) -> Void)?
    /// Called on the main thread on error / end of stream (it then reconnects automatically).
    var onError: ((String) -> Void)?

    private var url: URL?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var running = false
    private let decodeQueue = DispatchQueue(label: "mjpeg.decode")

    func start(url: URL) {
        stop()
        self.url = url
        running = true
        connect()
    }

    func stop() {
        running = false
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil; session = nil
        buffer.removeAll()
    }

    private func connect() {
        guard running, let url else { return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = .infinity
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        buffer.removeAll()
        task = s.dataTask(with: url)
        task?.resume()
    }

    // MARK: URLSessionDataDelegate (delegate queue, not the main thread)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        // Keep only the latest complete frame: if the Mac falls behind, frames are skipped.
        var latest: Data?
        while let start = buffer.firstRange(of: Data([0xFF, 0xD8])),
              let end = buffer[start.upperBound...].firstRange(of: Data([0xFF, 0xD9])) {
            latest = buffer.subdata(in: start.lowerBound..<end.upperBound)
            buffer.removeSubrange(..<end.upperBound)
        }
        if buffer.count > 8_000_000 { buffer.removeAll() }   // safety net
        if let latest {
            decodeQueue.async { [weak self] in
                guard let img = NSImage(data: latest) else { return }
                DispatchQueue.main.async { self?.onFrame?(img, latest) }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard running, session === self.session else { return }
        let msg = error?.localizedDescription ?? "stream ended"
        DispatchQueue.main.async { [weak self] in
            self?.onError?(msg)
            // Reconnect after 1 s (WDA restarted, cable unplugged, etc.).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.connect() }
        }
    }
}
