// HTTPMessage.swift
// The small part of HTTP/1.1 the MCP server needs: an incremental request parser (Content-Length
// and chunked bodies) and a response serializer. One request per connection; every response
// carries `Connection: close`, so there is no keep-alive or pipelining to get wrong.

import Foundation

struct HTTPRequest {
    let method: String
    /// Path without the query string, e.g. "/mcp".
    let path: String
    /// Header names are lowercased.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func empty(_ status: Int, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers)
    }

    static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data((message + "\n").utf8))
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = "\(body.count)"
        all["Connection"] = "close"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

/// Feed it the bytes read from the socket until it returns something other than `.needMore`.
struct HTTPRequestParser {
    enum Outcome {
        case needMore
        case complete(HTTPRequest)
        /// Malformed or oversized request: answer with this status and close.
        case failure(Int)
    }

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    private var buffer = Data()
    private var head: (method: String, path: String, headers: [String: String])?
    private var bodyStart = 0
    /// True once, right after the headers of a request with `Expect: 100-continue` are parsed.
    private(set) var wantsContinue = false

    mutating func consumeWantsContinue() -> Bool {
        defer { wantsContinue = false }
        return wantsContinue
    }

    mutating func feed(_ data: Data) -> Outcome {
        buffer.append(data)
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return buffer.count > Self.maxHeaderBytes ? .failure(431) : .needMore
            }
            guard end.lowerBound <= Self.maxHeaderBytes,
                  let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8),
                  let parsed = Self.parseHead(text) else { return .failure(end.lowerBound > Self.maxHeaderBytes ? 431 : 400) }
            head = parsed
            bodyStart = end.upperBound - buffer.startIndex
            wantsContinue = parsed.headers["expect"]?.lowercased() == "100-continue"
        }
        guard let head else { return .needMore }
        let available = buffer.count - bodyStart

        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch Self.decodeChunked(buffer.subdata(in: (buffer.startIndex + bodyStart)..<buffer.endIndex)) {
            case .needMore: return available > Self.maxBodyBytes * 2 ? .failure(413) : .needMore
            case .failure(let s): return .failure(s)
            case .body(let body): return .complete(HTTPRequest(method: head.method, path: head.path, headers: head.headers, body: body))
            }
        }

        let length: Int
        if let raw = head.headers["content-length"] {
            guard let n = Int(raw.trimmingCharacters(in: .whitespaces)), n >= 0 else { return .failure(400) }
            length = n
        } else {
            length = 0   // GET, DELETE…: no body
        }
        guard length <= Self.maxBodyBytes else { return .failure(413) }
        guard available >= length else { return .needMore }
        let start = buffer.startIndex + bodyStart
        let body = buffer.subdata(in: start..<(start + length))
        return .complete(HTTPRequest(method: head.method, path: head.path, headers: head.headers, body: body))
    }

    private static func parseHead(_ text: String) -> (method: String, path: String, headers: [String: String])? {
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let request = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard request.count == 3, request[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            headers[name] = value
        }
        let target = String(request[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return (String(request[0]).uppercased(), path, headers)
    }

    private enum Chunked { case needMore, body(Data), failure(Int) }

    private static func decodeChunked(_ data: Data) -> Chunked {
        var body = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return .needMore }
            guard let line = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii),
                  let size = Int(line.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16),
                  size >= 0 else { return .failure(400) }
            index = lineEnd.upperBound
            if size == 0 {
                // Trailers (if any) end with an empty line.
                return data.range(of: crlf, in: index..<data.endIndex) != nil || index == data.endIndex ? .body(body) : .needMore
            }
            guard body.count + size <= maxBodyBytes else { return .failure(413) }
            guard data.endIndex - index >= size + 2 else { return .needMore }
            body.append(data[index..<(index + size)])
            index += size + 2
        }
    }
}
