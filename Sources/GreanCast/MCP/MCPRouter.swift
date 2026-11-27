// MCPRouter.swift
// MCP over Streamable HTTP, stateless: one POST per JSON-RPC message, JSON responses, no SSE and
// no sessions. Both protocol eras are served on the same endpoint, chosen per request:
//   • modern (2026-07-28): no handshake; every request carries its protocol version and client
//     capabilities in `params._meta`, mirrored in the MCP-Protocol-Version / Mcp-Method /
//     Mcp-Name headers; `server/discover` describes the server.
//   • legacy (2025-03-26 … 2025-11-25): `initialize`, `notifications/initialized`, `ping`.
// Spec: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http

import Foundation

@MainActor
final class MCPRouter {
    static let modernVersions = ["2026-07-28"]
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private static let versionKey = "io.modelcontextprotocol/protocolVersion"
    private static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    private static let clientInfoKey = "io.modelcontextprotocol/clientInfo"

    private let settings: MCPSettings
    private let runner: MCPToolRunner
    /// Reports each tool call: tool name, client name if known, whether it failed, duration (ms).
    var onToolCall: ((String, String?, Bool, Int) -> Void)?

    init(settings: MCPSettings, runner: MCPToolRunner) {
        self.settings = settings
        self.runner = runner
    }

    private var serverInfo: [String: Any] {
        ["name": "greancast", "title": "GreanCast", "version": Bundle.main.shortVersion]
    }

    private var listedTools: [[String: Any]] {
        MCPTools.all.filter { settings.allows($0.permission) }.map(\.json)
    }

    /// Handles the body of a POST to the MCP endpoint.
    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            // Batches (arrays) were only in 2025-03-26 and no client sends them.
            return .json(400, Self.error(id: nil, -32700, "Parse error: the body must be one JSON-RPC object"))
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response to a server request: this server never sends any.
            return id == nil ? .json(400, Self.error(id: nil, -32600, "Invalid request")) : .empty(202)
        }
        guard let id, !(id is NSNull) else { return .empty(202) }   // notification
        let params = message["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any] ?? [:]

        if meta[Self.versionKey] != nil {
            return await modern(request, id: id, method: method, params: params, meta: meta)
        }
        return await legacy(request, id: id, method: method, params: params)
    }

    // MARK: - Modern era

    private func modern(_ request: HTTPRequest, id: Any, method: String, params: [String: Any],
                        meta: [String: Any]) async -> HTTPResponse {
        let version = meta[Self.versionKey] as? String ?? ""
        guard Self.modernVersions.contains(version) else {
            return .json(400, Self.error(id: id, -32022, "Unsupported protocol version",
                                         data: ["supported": Self.modernVersions + Self.legacyVersions, "requested": version]))
        }
        guard request.header("MCP-Protocol-Version") == version else {
            return .json(400, Self.error(id: id, -32020, "Header mismatch: MCP-Protocol-Version header value '\(request.header("MCP-Protocol-Version") ?? "")' does not match body value '\(version)'"))
        }
        guard request.header("Mcp-Method") == method else {
            return .json(400, Self.error(id: id, -32020, "Header mismatch: Mcp-Method header value '\(request.header("Mcp-Method") ?? "")' does not match body value '\(method)'"))
        }
        guard meta[Self.capabilitiesKey] is [String: Any] else {
            return .json(400, Self.error(id: id, -32602, "Invalid params: _meta is missing \(Self.capabilitiesKey)"))
        }
        let client = (meta[Self.clientInfoKey] as? [String: Any])?["name"] as? String

        switch method {
        case "server/discover":
            return .json(200, Self.result(id: id, [
                "resultType": "complete",
                "supportedVersions": Self.modernVersions + Self.legacyVersions,
                "capabilities": ["tools": [String: Any]()],
                "instructions": MCPTools.instructions,
                "_meta": ["io.modelcontextprotocol/serverInfo": serverInfo],
                "ttlMs": 60_000,
                "cacheScope": "private",
            ]))
        case "tools/list":
            // ttlMs 0: the list follows the permission switches, which can change at any time.
            return .json(200, Self.result(id: id, ["resultType": "complete", "tools": listedTools, "ttlMs": 0, "cacheScope": "private"]))
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard Self.decodeHeader(request.header("Mcp-Name")) == name else {
                return .json(400, Self.error(id: id, -32020, "Header mismatch: Mcp-Name header value '\(request.header("Mcp-Name") ?? "")' does not match body value '\(name)'"))
            }
            return await callTool(id: id, params: params, client: client, modern: true)
        default:
            return .json(404, Self.error(id: id, -32601, "Method not found: \(method)"))
        }
    }

    /// Header values that are not plain ASCII are sent as `=?base64?…?=`.
    private static func decodeHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?="),
              let data = Data(base64Encoded: String(value.dropFirst(9).dropLast(2))) else { return value }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Legacy era

    private var legacyClient: String?

    private func legacy(_ request: HTTPRequest, id: Any, method: String, params: [String: Any]) async -> HTTPResponse {
        if let header = request.header("MCP-Protocol-Version"),
           !Self.legacyVersions.contains(header), !Self.modernVersions.contains(header) {
            return .json(400, Self.error(id: id, -32600, "Unsupported MCP-Protocol-Version: \(header)",
                                         data: ["supported": Self.modernVersions + Self.legacyVersions]))
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            legacyClient = (params["clientInfo"] as? [String: Any])?["name"] as? String
            return .json(200, Self.result(id: id, [
                "protocolVersion": Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": serverInfo,
                "instructions": MCPTools.instructions,
            ]))
        case "ping":
            return .json(200, Self.result(id: id, [:]))
        case "tools/list":
            return .json(200, Self.result(id: id, ["tools": listedTools]))
        case "tools/call":
            return await callTool(id: id, params: params, client: legacyClient, modern: false)
        default:
            return .json(200, Self.error(id: id, -32601, "Method not found: \(method)"))
        }
    }

    // MARK: - Tools

    private func callTool(id: Any, params: [String: Any], client: String?, modern: Bool) async -> HTTPResponse {
        let name = params["name"] as? String ?? ""
        // A tool whose permission is off is not listed, so it is unknown to the client.
        guard let tool = MCPTools.tool(named: name) else {
            return .json(modern ? 400 : 200, Self.error(id: id, -32602, "Unknown tool: \(name)"))
        }
        let start = Date()
        let result: MCPToolResult
        if settings.allows(tool.permission) {
            result = await runner.call(tool, arguments: params["arguments"] as? [String: Any] ?? [:])
        } else {
            result = .error("\"\(tool.permission.label)\" is turned off in GreanCast › Settings › MCP.")
        }
        onToolCall?(name, client, result.isError, Int(Date().timeIntervalSince(start) * 1000))
        var body: [String: Any] = ["content": result.content, "isError": result.isError]
        if modern { body["resultType"] = "complete" }
        return .json(200, Self.result(id: id, body))
    }

    // MARK: - JSON-RPC

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: Any?, _ code: Int, _ message: String, data: [String: Any]? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        var out: [String: Any] = ["jsonrpc": "2.0", "error": error]
        if let id { out["id"] = id }
        return out
    }
}
