// MARK: - Relay.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Store-and-forward for queue dispatches. FilmTracker can send to this always-on Mac
// (Bonjour `_atvqrelay._tcp`) instead of the Apple TV; the relay keeps the newest queue,
// pushes it to every ATVQ it can find (`_atvq._tcp`), and hands it to ATVQ on request
// when ATVQ launches or wakes. ATVQ keeps whichever payload is newest, so FilmTracker
// sending directly as well never causes a conflict.
//
// Frames are a 4-byte big-endian length then JSON — the same protocol ATVQ speaks:
//   {"version":…, "dispatchedAt":…, "films":[…]}  → store, reply {"ok":true}
//   {"fetch":true}                                 → reply with the held payload (or {"ok":true})

import Foundation
import Network
import Observation

@Observable
final class Relay {
    private(set) var heldDispatchedAt: Date?
    private(set) var filmCount = 0
    private(set) var deliveries: [String: Date] = [:]   // ATVQ instance name → time delivered
    private(set) var isListening = false
    @ObservationIgnored var log: (String) -> Void = { _ in }

    private var held: Data?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var targets: [String: NWEndpoint] = [:]
    private var delivered: Set<String> = []             // instance names holding the current queue
    private var inFlight: Set<String> = []
    private var retryTimer: Timer?
    private var restartDelay: TimeInterval = 2
    /// Pushes happen only for a short while after a dispatch arrives. A sleeping Apple TV
    /// can stay advertised through the network's Bonjour Sleep Proxy, and connecting to it
    /// can wake it — and, via HDMI-CEC, the home theater. Pushing indefinitely could do
    /// that all night. After the window, ATVQ's own fetch on launch/wake delivers the queue.
    private var pushUntil: Date?
    private static let pushWindow: TimeInterval = 10 * 60

    private static var fileURL: URL { Storage.directory.appendingPathComponent("relay-payload.json") }
    /// Lab use only (`defaults write app.ATVQDeployer RelayLoopback -bool YES`): forces
    /// forwarding over loopback so the tvOS Simulator on this Mac is reachable.
    private var loopbackOnly: Bool { UserDefaults.standard.bool(forKey: "RelayLoopback") }

    func start() {
        guard listener == nil else { return }
        if let data = try? Data(contentsOf: Self.fileURL), let date = Self.dispatchedAt(in: data) {
            held = data
            heldDispatchedAt = date
            filmCount = Self.filmCount(in: data)
        }
        startListener()
        startBrowser()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.forwardToAll() }
        }
    }

    // MARK: Listening for FilmTracker (and ATVQ fetches)

    private func startListener() {
        guard let listener = try? NWListener(using: .tcp) else { scheduleRestart(); return }
        listener.service = NWListener.Service(type: "_atvqrelay._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    self?.isListening = true
                    self?.restartDelay = 2
                    self?.log("Relay listening.")
                case .failed(let error), .waiting(let error):
                    self?.isListening = false
                    self?.log("Relay listener: \(error); restarting.")
                    self?.scheduleRestart()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.handle(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func scheduleRestart() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 120)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if self?.listener == nil { self?.startListener() }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { connection.cancel() }
        Frames.receive(on: connection) { [weak self] body in
            guard let self, let body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                Self.reply(#"{"ok":false,"error":"Invalid frame"}"#, on: connection); return
            }
            if object["fetch"] as? Bool == true {
                self.log("ATVQ asked for the latest queue\(self.held == nil ? " (none held)" : "").")
                connection.send(content: Frames.frame(self.held ?? Data(#"{"ok":true}"#.utf8)),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            guard object["films"] != nil, let date = Self.dispatchedAt(in: body) else {
                Self.reply(#"{"ok":false,"error":"Not a queue payload"}"#, on: connection); return
            }
            Self.reply(#"{"ok":true}"#, on: connection)
            self.accept(body, dispatchedAt: date)
        }
    }

    private func accept(_ body: Data, dispatchedAt date: Date) {
        // Older, or the identical queue again, is ignored; a different queue with the same
        // (second-precision) timestamp is accepted.
        if let heldDispatchedAt, date < heldDispatchedAt || (date == heldDispatchedAt && body == held) {
            log("Relay ignored a queue no newer than the one held.")
            return
        }
        held = body
        heldDispatchedAt = date
        filmCount = Self.filmCount(in: body)
        delivered.removeAll()
        deliveries.removeAll()
        try? body.write(to: Self.fileURL, options: .atomic)
        pushUntil = Date().addingTimeInterval(Self.pushWindow)
        log("Relay received a queue of \(filmCount) film(s); forwarding.")
        forwardToAll()
    }

    // MARK: Forwarding to ATVQ

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: "_atvq._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.targets = Dictionary(results.compactMap { result -> (String, NWEndpoint)? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return (name, result.endpoint)
                }, uniquingKeysWith: { first, _ in first })
                // An ATVQ that (re)appears — e.g. the Apple TV woke — gets the queue right away.
                self.delivered.formIntersection(self.targets.keys)
                self.forwardToAll()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed = state {
                    self?.browser = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.startBrowser() }
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func forwardToAll() {
        guard let held, let pushUntil, Date() < pushUntil else { return }
        for (name, endpoint) in targets where !delivered.contains(name) && !inFlight.contains(name) {
            forward(held, to: name, endpoint: endpoint)
        }
    }

    private func forward(_ body: Data, to name: String, endpoint: NWEndpoint) {
        inFlight.insert(name)
        let parameters = NWParameters.tcp
        if loopbackOnly { parameters.requiredInterfaceType = .loopback }
        let connection = NWConnection(to: endpoint, using: parameters)
        var finished = false
        let finish: @MainActor (Bool, String) -> Void = { [weak self] ok, detail in
            guard !finished, let self else { return }
            finished = true
            connection.cancel()
            self.inFlight.remove(name)
            // Only count it if the queue wasn't replaced while this was in flight.
            if ok, self.held == body {
                self.delivered.insert(name)
                self.deliveries[name] = Date()
                self.log("Relay delivered the queue to \(name).")
            } else if !ok {
                self.log("Relay couldn't reach \(name) (\(detail)); will retry.")
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish(false, "timed out") }
        connection.send(content: Frames.frame(body), completion: .contentProcessed { error in
            if let error { MainActor.assumeIsolated { finish(false, "\(error)") } }
        })
        Frames.receive(on: connection) { reply in
            let ok = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["ok"] as? Bool == true
            finish(ok, reply.map { String(decoding: $0, as: UTF8.self) } ?? "no reply")
        }
    }

    // MARK: Helpers

    private static func reply(_ json: String, on connection: NWConnection) {
        connection.send(content: Frames.frame(Data(json.utf8)), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func dispatchedAt(in body: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = object["dispatchedAt"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    private static func filmCount(in body: Data) -> Int {
        ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["films"] as? [Any])?.count ?? 0
    }
}

/// Length-prefixed framing shared with ATVQ (see QueuePayload.swift there).
nonisolated enum Frames {
    static let maxBytes = 64 * 1024 * 1024

    static func frame(_ body: Data) -> Data {
        let length = UInt32(body.count)
        return Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) }) + body
    }

    static func receive(on connection: NWConnection, completion: @escaping @MainActor (Data?) -> Void) {
        receiveExactly(4, on: connection) { header in
            guard let header else { completion(nil); return }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= maxBytes else { completion(nil); return }
            receiveExactly(length, on: connection, completion: completion)
        }
    }

    /// Network.framework buffers until exactly `count` bytes arrive (or the connection ends).
    private static func receiveExactly(_ count: Int, on connection: NWConnection,
                                       completion: @escaping @MainActor (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
            Task { @MainActor in completion(data?.count == count ? data : nil) }
        }
    }
}
