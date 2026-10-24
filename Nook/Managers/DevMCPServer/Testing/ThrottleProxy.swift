// Licensed under GPL-3.0. See LICENSE.
//
//  ThrottleProxy.swift
//  Nook
//
//  A local CONNECT proxy that slows `inspect(network:)` to a phone network: the first bytes each
//  way wait the profile's delay, and every connection shares one link's speed, as on a phone, so
//  a page opening six connections does not get six times the speed. It runs only during that
//  call, for that call's throwaway data store, so nothing else the person does goes through it.
//

import Foundation
import Network

final class ThrottleProxy: @unchecked Sendable {
    enum Profile: String, CaseIterable {
        case slow3g, fast3g, fourG = "4g"

        var latency: TimeInterval {
            switch self {
            case .slow3g: 0.4
            case .fast3g: 0.15
            case .fourG: 0.05
            }
        }

        var bytesPerSecond: Int {
            switch self {
            case .slow3g: 400_000 / 8
            case .fast3g: 1_600_000 / 8
            case .fourG: 9_000_000 / 8
            }
        }
    }

    let profile: Profile
    private let queue = DispatchQueue(label: "com.qusai.nook.throttle-proxy")
    private let listener: NWListener
    private let up: Pacer
    private let down: Pacer
    private var tunnels: [ObjectIdentifier: Tunnel] = [:]
    private var started: CheckedContinuation<UInt16, Error>?

    init(profile: Profile) throws {
        self.profile = profile
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        up = Pacer(bytesPerSecond: profile.bytesPerSecond)
        down = Pacer(bytesPerSecond: profile.bytesPerSecond)
    }

    /// Starts listening on 127.0.0.1 and answers the port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.started = continuation
                self.listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            self.tunnels.values.forEach { $0.cancel() }
            self.tunnels.removeAll()
        }
    }

    /// The setting that sends a data store's connections through this proxy.
    func proxyConfiguration(port: UInt16) -> ProxyConfiguration {
        ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!))
    }

    // MARK: - Connections

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            started?.resume(returning: listener.port?.rawValue ?? 0)
            started = nil
        case .failed(let error):
            started?.resume(throwing: error)
            started = nil
        default:
            break
        }
    }

    private func accept(_ client: NWConnection) {
        let tunnel = Tunnel(client: client)
        tunnels[ObjectIdentifier(tunnel)] = tunnel
        client.stateUpdateHandler = { [weak self, weak tunnel] state in
            guard let self, let tunnel else { return }
            if case .failed = state { self.close(tunnel) }
        }
        client.start(queue: queue)
        readRequest(tunnel, Data())
    }

    /// Reads up to the end of the request's header lines.
    private func readRequest(_ tunnel: Tunnel, _ buffer: Data) {
        tunnel.client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.open(tunnel, request: buffer[..<end.lowerBound], rest: Data(buffer[end.upperBound...]))
            } else if isComplete || error != nil || buffer.count > 16_384 {
                self.close(tunnel)
            } else {
                self.readRequest(tunnel, buffer)
            }
        }
    }

    /// `CONNECT host:port` opens the tunnel; anything else (a plain-HTTP proxy request) gets 501.
    private func open(_ tunnel: Tunnel, request: Data, rest: Data) {
        let words = String(decoding: request.prefix { $0 != 13 }, as: UTF8.self).split(separator: " ")
        guard words.count >= 2, words[0] == "CONNECT", let colon = words[1].lastIndex(of: ":"),
              let port = NWEndpoint.Port(String(words[1][words[1].index(after: colon)...])) else {
            answer(tunnel, "HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", thenClose: true)
            return
        }
        var host = String(words[1][..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        tunnel.upstream = upstream
        upstream.stateUpdateHandler = { [weak self, weak tunnel] state in
            guard let self, let tunnel else { return }
            switch state {
            case .ready:
                self.answer(tunnel, "HTTP/1.1 200 Connection Established\r\n\r\n", thenClose: false)
                if !rest.isEmpty { self.forward(rest, on: tunnel.toUpstream, to: upstream, pacer: self.up) }
                self.relay(from: tunnel.client, to: upstream, pipe: tunnel.toUpstream, pacer: self.up, tunnel)
                self.relay(from: upstream, to: tunnel.client, pipe: tunnel.toClient, pacer: self.down, tunnel)
            case .waiting, .failed:
                // A host that cannot be reached waits forever; the page should see a failure.
                self.answer(tunnel, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", thenClose: true)
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func answer(_ tunnel: Tunnel, _ text: String, thenClose: Bool) {
        tunnel.client.send(content: Data(text.utf8), completion: .contentProcessed { [weak self, weak tunnel] _ in
            guard thenClose, let self, let tunnel else { return }
            self.close(tunnel)
        })
    }

    /// Reads one side and hands the bytes to the other at the profile's pace; the end of the
    /// stream follows the last byte.
    private func relay(from source: NWConnection, to sink: NWConnection, pipe: Pipe, pacer: Pacer, _ tunnel: Tunnel) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak tunnel] data, _, isComplete, error in
            guard let self, let tunnel else { return }
            if let data, !data.isEmpty { self.forward(data, on: pipe, to: sink, pacer: pacer) }
            if error != nil {
                self.close(tunnel)
            } else if isComplete {
                self.queue.asyncAfter(deadline: pipe.last) {
                    sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                }
                pipe.ended = true
                if tunnel.toUpstream.ended, tunnel.toClient.ended {
                    self.queue.asyncAfter(deadline: max(tunnel.toUpstream.last, tunnel.toClient.last) + 1) { self.close(tunnel) }
                }
            } else {
                self.relay(from: source, to: sink, pipe: pipe, pacer: pacer, tunnel)
            }
        }
    }

    /// Queues `data` for `sink` in chunks a tenth of a second long, each sent when the shared link
    /// would have finished carrying it. The first bytes each way also wait the profile's delay.
    private func forward(_ data: Data, on pipe: Pipe, to sink: NWConnection, pacer: Pacer) {
        let chunkSize = max(1, profile.bytesPerSecond / 10)
        var notBefore = DispatchTime.now()
        if !pipe.started {
            pipe.started = true
            notBefore = notBefore + profile.latency
        }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            let chunk = data.subdata(in: offset..<end)
            let at = pacer.reserve(bytes: chunk.count, notBefore: notBefore)
            pipe.last = at
            queue.asyncAfter(deadline: at) { sink.send(content: chunk, completion: .idempotent) }
            offset = end
        }
    }

    private func close(_ tunnel: Tunnel) {
        tunnel.cancel()
        tunnels[ObjectIdentifier(tunnel)] = nil
    }

    // MARK: - Types

    /// One direction of the shared link: every connection's bytes take turns at its speed.
    private final class Pacer {
        let bytesPerSecond: Double
        private var free = DispatchTime.now()

        init(bytesPerSecond: Int) { self.bytesPerSecond = Double(bytesPerSecond) }

        /// When `bytes` queued no earlier than `notBefore` have finished crossing the link.
        func reserve(bytes: Int, notBefore: DispatchTime) -> DispatchTime {
            free = max(notBefore, free) + Double(bytes) / bytesPerSecond
            return free
        }
    }

    /// One direction of one tunnel.
    private final class Pipe {
        var started = false
        var ended = false
        var last = DispatchTime.now()
    }

    private final class Tunnel {
        let client: NWConnection
        var upstream: NWConnection?
        let toUpstream = Pipe()
        let toClient = Pipe()

        init(client: NWConnection) { self.client = client }

        func cancel() {
            client.cancel()
            upstream?.cancel()
        }
    }
}
