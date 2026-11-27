// HTTPServer.swift
// TCP listener for the MCP endpoint (Network.framework). Bound to 127.0.0.1 unless network
// access is enabled, in which case it listens on every interface and the caller filters by
// remote address. Each connection carries one request and is closed after the response.

import Foundation
import Network

/// Where a request comes from, as seen by the listener.
struct HTTPPeer {
    let address: String
    let isLoopback: Bool
    /// Private (RFC 1918), link-local or unique-local address: a machine on the local network.
    let isLocalNetwork: Bool

    init(endpoint: NWEndpoint) {
        guard case .hostPort(let host, _) = endpoint else {
            address = "\(endpoint)"; isLoopback = false; isLocalNetwork = false
            return
        }
        var bytes: [UInt8] = []
        var v6 = false
        switch host {
        case .ipv4(let a): bytes = [UInt8](a.rawValue)
        case .ipv6(let a):
            if let mapped = a.asIPv4 { bytes = [UInt8](mapped.rawValue) } else { bytes = [UInt8](a.rawValue); v6 = true }
        default: break
        }
        if !v6, bytes.count == 4 {
            address = bytes.map(String.init).joined(separator: ".")
            isLoopback = bytes[0] == 127
            isLocalNetwork = bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        } else if v6, bytes.count == 16 {
            address = "\(host)"
            isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
            isLocalNetwork = (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) || (bytes[0] & 0xfe) == 0xfc
        } else {
            address = "\(host)"; isLoopback = false; isLocalNetwork = false
        }
    }
}

final class HTTPServer {
    enum State: Equatable {
        case stopped
        case listening
        case failed(String)
    }

    typealias Handler = (HTTPRequest, HTTPPeer, @escaping (HTTPResponse) -> Void) -> Void

    /// Called on the main thread.
    var onState: ((State) -> Void)?
    /// Called on the server queue when an accepted connection could not be used.
    var onConnectionProblem: ((String) -> Void)?

    private let queue = DispatchQueue(label: "mcp.http")
    private var listener: NWListener?
    private let handler: Handler
    private static let readTimeout: TimeInterval = 10

    /// `handler` runs on the server queue and must call its completion exactly once.
    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts listening. A previous listener is fully cancelled first, so the port can be reused.
    func start(port: UInt16, loopbackOnly: Bool) {
        queue.async { [self] in
            guard let old = listener else { open(port: port, loopbackOnly: loopbackOnly); return }
            listener = nil
            old.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.open(port: port, loopbackOnly: loopbackOnly) }
            }
            old.cancel()
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
            report(.stopped)
        }
    }

    private func open(port: UInt16, loopbackOnly: Bool) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { report(.failed("invalid port \(port)")); return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let l: NWListener
            if loopbackOnly {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
                l = try NWListener(using: params)
            } else {
                l = try NWListener(using: params, on: nwPort)
            }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self, let l, self.listener === l else { return }
                switch state {
                case .ready: self.report(.listening)
                case .failed(let error):
                    l.cancel()
                    self.listener = nil
                    self.report(.failed(Self.message(error, port: port)))
                case .waiting(let error): self.report(.failed(Self.message(error, port: port)))
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            listener = l
            l.start(queue: queue)
        } catch {
            report(.failed(Self.message(error, port: port)))
        }
    }

    private static func message(_ error: Error, port: UInt16) -> String {
        if case NWError.posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use by another process"
        }
        return error.localizedDescription
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let peer = HTTPPeer(endpoint: connection.endpoint)
        var parser = HTTPRequestParser()
        var finished = false
        var dispatched = false

        func reply(_ response: HTTPResponse) {
            guard !finished else { return }
            finished = true
            connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }

        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !finished else { return }
                if let data, !data.isEmpty {
                    switch parser.feed(data) {
                    case .complete(let request):
                        dispatched = true
                        self.handler(request, peer) { response in self.queue.async { reply(response) } }
                        return
                    case .failure(let status):
                        reply(.text(status, "Bad request"))
                        return
                    case .needMore:
                        if parser.consumeWantsContinue() {
                            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                        }
                    }
                }
                if isComplete || error != nil { finished = true; connection.cancel(); return }
                read()
            }
        }

        // A connection that never becomes ready is usually macOS withholding Local Network access.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let error), .failed(let error):
                self?.onConnectionProblem?("connection from \(peer.address) did not open: \(error.localizedDescription)")
                finished = true
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        read()
        // A client that connects and never sends a full request is dropped. The timeout only
        // applies while the request is being read, not while a tool runs.
        queue.asyncAfter(deadline: .now() + Self.readTimeout) {
            if !finished, !dispatched { reply(.text(408, "Request timeout")) }
        }
    }
}
