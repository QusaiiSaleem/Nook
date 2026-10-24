// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc -parse-as-library Nook/Managers/DevMCPServer/Testing/ThrottleProxy.swift \
//         scripts/tests/ThrottleProxyCheck.swift -o /tmp/tp && /tmp/tp
//
//  The slow-network proxy behind `inspect(network:)`, against a local echo server: a CONNECT
//  tunnel carries bytes unchanged at the profile's delay and speed, connections share one link's
//  speed as on a phone, and anything that is not CONNECT is refused.

import Foundation
import Network

@main
struct ThrottleProxyCheck {
    static let queue = DispatchQueue(label: "throttle-check")

    static func main() async throws {
        let echo = try await EchoServer.start()
        try await slow3g_round_trip_is_delayed_and_unchanged(echo: echo)
        try await fourG_round_trip_is_quick(echo: echo)
        try await connections_share_one_link(echo: echo)
        try await plain_requests_are_refused(echo: echo)
        print("ThrottleProxyCheck passed")
    }

    // MARK: - Checks

    static func slow3g_round_trip_is_delayed_and_unchanged(echo: UInt16) async throws {
        let proxy = try ThrottleProxy(profile: .slow3g)
        let port = try await proxy.start()
        defer { proxy.stop() }
        precondition(ThrottleProxy.Profile.slow3g.bytesPerSecond == 50_000 && ThrottleProxy.Profile.slow3g.latency == 0.4)
        let payload = Data((0..<40_000).map { _ in UInt8.random(in: 0...255) })
        let (echoed, took) = try await roundTrip(payload, proxy: port, echo: echo)
        precondition(echoed == payload, "the tunnel changed the bytes")
        // 0.4 s delay + 40 KB at 50 KB/s.
        precondition(took >= 1.2, "slow3g round trip took only \(took) s")
        precondition(took < 5, "slow3g round trip took \(took) s")
    }

    static func fourG_round_trip_is_quick(echo: UInt16) async throws {
        let proxy = try ThrottleProxy(profile: .fourG)
        let port = try await proxy.start()
        defer { proxy.stop() }
        let payload = Data(repeating: 7, count: 40_000)
        let (echoed, took) = try await roundTrip(payload, proxy: port, echo: echo)
        precondition(echoed == payload, "the tunnel changed the bytes")
        precondition(took < 0.5, "4g round trip took \(took) s")
    }

    /// Four tunnels at once share 50 KB/s: 40 KB in total takes 0.8 s of transfer, where a speed
    /// limit per tunnel would finish each 10 KB in 0.2 s.
    static func connections_share_one_link(echo: UInt16) async throws {
        let proxy = try ThrottleProxy(profile: .slow3g)
        let port = try await proxy.start()
        defer { proxy.stop() }
        let payload = Data(repeating: 1, count: 10_000)
        let took = try await withThrowingTaskGroup(of: TimeInterval.self) { group in
            for _ in 0..<4 { group.addTask { try await roundTrip(payload, proxy: port, echo: echo).took } }
            var slowest: TimeInterval = 0
            for try await took in group { slowest = max(slowest, took) }
            return slowest
        }
        precondition(took >= 1.5, "four tunnels finished in \(took) s: each got the whole link")
    }

    static func plain_requests_are_refused(echo: UInt16) async throws {
        let proxy = try ThrottleProxy(profile: .fourG)
        let port = try await proxy.start()
        defer { proxy.stop() }
        let connection = try await connect(port)
        defer { connection.cancel() }
        try await send(connection, Data("GET http://127.0.0.1:\(echo)/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        let answer = try await receive(connection) { $0.range(of: Data("\r\n\r\n".utf8)) != nil }
        precondition(String(decoding: answer, as: UTF8.self).hasPrefix("HTTP/1.1 501"), "answer: \(String(decoding: answer, as: UTF8.self))")
    }

    // MARK: - Helpers

    /// Opens a tunnel to the echo server and times the payload going there and back.
    static func roundTrip(_ payload: Data, proxy: UInt16, echo: UInt16) async throws -> (echoed: Data, took: TimeInterval) {
        let connection = try await connect(proxy)
        defer { connection.cancel() }
        try await send(connection, Data("CONNECT 127.0.0.1:\(echo) HTTP/1.1\r\nHost: 127.0.0.1:\(echo)\r\n\r\n".utf8))
        let head = try await receive(connection) { $0.range(of: Data("\r\n\r\n".utf8)) != nil }
        precondition(String(decoding: head, as: UTF8.self).hasPrefix("HTTP/1.1 200"), "CONNECT answer: \(String(decoding: head, as: UTF8.self))")
        let start = Date()
        try await send(connection, payload)
        let echoed = try await receive(connection) { $0.count >= payload.count }
        return (echoed, Date().timeIntervalSince(start))
    }

    static func connect(_ port: UInt16) async throws -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if ready.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error): if ready.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
        return connection
    }

    static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Reads until `done` says the bytes so far are enough, or for 10 s.
    static func receive(_ connection: NWConnection, until done: @escaping @Sendable (Data) -> Bool) async throws -> Data {
        let deadline = Date().addingTimeInterval(10)
        var buffer = Data()
        while !done(buffer) {
            precondition(Date() < deadline, "nothing more arrived; have \(buffer.count) bytes")
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if isComplete { continuation.resume(throwing: NWError.posix(.ECONNRESET)) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }
}

/// A server that sends back whatever it receives.
enum EchoServer {
    static func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: ThrottleProxyCheck.queue)
            echo(connection)
        }
        listener.start(queue: ThrottleProxyCheck.queue)
        while (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        kept.append(listener)
        return listener.port!.rawValue
    }

    nonisolated(unsafe) static var kept: [NWListener] = []

    static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty { connection.send(content: data, completion: .idempotent) }
            if isComplete || error != nil { connection.cancel() } else { echo(connection) }
        }
    }
}

/// Lets exactly one of several callbacks resume a continuation.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
