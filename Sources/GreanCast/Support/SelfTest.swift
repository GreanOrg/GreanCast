// SelfTest.swift
// `GreanCast --selftest <file.png>`: waits for the connection, measures the video frame rate
// and the latency of a Home press, saves the current frame and quits. Used to check the whole
// chain (USB tunnel → WDA session → MJPEG → command queue) without clicking. It then exercises the
// MCP server over HTTP on a test port (handshake, tool list, screenshot, UI description).

import AppKit

@MainActor
enum SelfTest {
    static func runIfRequested(_ session: DeviceSession, mcp: MCPServer) {
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
            await testMCP(mcp, wait: wait)
            log.info("selftest: done")
            NSApp.terminate(nil)
        }
    }

    private static let mcpPort = 8799

    /// Talks to the MCP server as a client would, in both protocol eras, and logs latencies.
    private static func testMCP(_ mcp: MCPServer, wait: (Double) async -> Void) async {
        let log = Log.shared
        mcp.startForSelfTest(port: mcpPort)
        for _ in 0..<40 where mcp.state != .listening { await wait(0.05) }
        guard mcp.state == .listening else { log.error("selftest: MCP server did not start (\(mcp.state))"); return }

        func post(_ method: String, _ params: [String: Any], modern: Bool = false) async -> (ms: Int, result: [String: Any]?) {
            var params = params
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(mcpPort)/mcp")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if modern {
                let version = MCPRouter.modernVersions[0]
                params["_meta"] = ["io.modelcontextprotocol/protocolVersion": version,
                                   "io.modelcontextprotocol/clientCapabilities": [String: Any](),
                                   "io.modelcontextprotocol/clientInfo": ["name": "selftest", "version": "1"]] as [String: Any]
                req.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
                req.setValue(method, forHTTPHeaderField: "Mcp-Method")
                if let name = params["name"] as? String { req.setValue(name, forHTTPHeaderField: "Mcp-Name") }
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            let t0 = Date()
            let data = (try? await URLSession.shared.data(for: req))?.0 ?? Data()
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (Int(Date().timeIntervalSince(t0) * 1000), json?["result"] as? [String: Any])
        }

        func summary(_ result: [String: Any]?) -> String {
            let blocks = result?["content"] as? [[String: Any]] ?? []
            let failed = result?["isError"] as? Bool ?? true
            return (failed ? "FAILED " : "") + blocks.map { b in
                if let data = b["data"] as? String { return "image \(data.count * 3 / 4 / 1024) kB" }
                return String((b["text"] as? String ?? "").prefix(90)).replacingOccurrences(of: "\n", with: " ⏎ ")
            }.joined(separator: " | ")
        }

        let initialize = await post("initialize", ["protocolVersion": "2025-11-25", "capabilities": [String: Any](),
                                                   "clientInfo": ["name": "selftest", "version": "1"]])
        log.info("selftest: MCP initialize → \(initialize.result?["protocolVersion"] ?? "FAILED")")
        let discover = await post("server/discover", [:], modern: true)
        log.info("selftest: MCP server/discover → \(discover.result?["supportedVersions"] ?? "FAILED")")
        let list = await post("tools/list", [:], modern: true)
        log.info("selftest: MCP tools/list → \((list.result?["tools"] as? [Any])?.count ?? -1) tools")
        for (tool, arguments) in [("screenshot", [:]), ("screenshot_with_metadata", [:]), ("describe_ui", [:]),
                                  ("list_apps", ["scope": "user"]),
                                  ("press_button", ["button": "home", "screenshot": true])] as [(String, [String: Any])] {
            let r = await post("tools/call", ["name": tool, "arguments": arguments], modern: tool != "screenshot")
            log.info("selftest: MCP \(tool) \(r.ms) ms → \(summary(r.result))")
        }
    }
}
