// MARK: - RelayClient.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Pulls the latest queue from the ATVQ Deployer relay (on the always-on Mac) for as long as
// ATVQ is in the foreground. This is the path that's always there: the relay always holds the
// newest dispatch (FilmTracker always sends to it), so polling it delivers a dispatch whether
// it was sent while the Apple TV slept or a moment ago. Direct pushes (from FilmTracker or the
// relay) still arrive through QueueListener and just get here sooner; the store keeps
// whichever payload is newest.
//
// On activation the relay is asked right away and then every few seconds until it answers,
// since a waking Apple TV can take a while to get its network back; after that, every
// `pollInterval`. Each request says which dispatch ATVQ already has, so a poll costs a few
// bytes unless something newer is held.
//
// Request:  framed JSON {"fetch": true, "have": "<dispatchedAt of the newest queue held>",
//                        "haveFilms": ["<film IDs of that queue>"]}
// Response: framed QueuePayload, or framed QueueReply when the relay holds nothing newer.
// After a payload, ATVQ answers with a framed QueueReply so the relay can log delivery.

import Foundation
import Network
import os

final class RelayClient {
    static let serviceType = "_atvqrelay._tcp"

    private static let pollInterval: TimeInterval = 20
    private static let retryInterval: TimeInterval = 3

    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []
    private var inFlight: Set<String> = []
    /// Open fetches, cancelled on stop: one left over from before a sleep would otherwise keep
    /// its endpoint marked in flight, so polls after waking skip it until it times out.
    private var connections: [String: NWConnection] = [:]
    /// Bumped on stop, so callbacks from an earlier activation are ignored.
    private var session = 0
    private var timer: Timer?
    /// Until the relay first answers after activation, ask often.
    private var answeredSinceActivation = false
    private var have: () -> (date: Date, filmIDs: [UUID])? = { nil }
    private var onPayload: ((QueuePayload) -> Void)?
    /// Reports whether the first check after activation reached the relay (true), or gave up
    /// after `checkGrace` (false). Polling carries on either way.
    private var onChecked: ((Bool) -> Void)?
    private static let checkGrace: TimeInterval = 45

    /// Starts (or restarts, on returning to the foreground) browsing and polling.
    func start(have: @escaping () -> (date: Date, filmIDs: [UUID])?, onPayload: @escaping (QueuePayload) -> Void,
               onChecked: @escaping (Bool) -> Void) {
        self.have = have
        self.onPayload = onPayload
        stop()
        self.onChecked = onChecked
        let session = self.session
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkGrace) { [weak self] in
            guard let self, self.session == session, !self.answeredSinceActivation else { return }
            Log.relay.info("No answer from a relay yet; still trying.")
            self.onChecked?(false)
            self.onChecked = nil
        }
        Log.relay.info("Activated; looking for the relay.")
        answeredSinceActivation = false
        startBrowser()
        scheduleNext()
    }

    /// The app left the foreground: nothing runs while suspended anyway.
    func stop() {
        timer?.invalidate()
        timer = nil
        session += 1
        connections.values.forEach { $0.cancel() }
        connections = [:]
        inFlight = []
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        endpoints = []
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endpoints = results.map(\.endpoint)
                Log.relay.info("Relays found: \(self.endpoints.isEmpty ? "none" : self.endpoints.map { "\($0)" }.joined(separator: ", "), privacy: .public)")
                self.pollNow()
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                // A browser started before the network is up can fail outright; try again.
                Log.relay.info("Browser: \(String(describing: state), privacy: .public)")
                guard case .failed = state, let self, self.browser === browser else { return }
                self.browser?.cancel()
                self.browser = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
                    guard let self, self.browser == nil, self.onPayload != nil, self.timer != nil else { return }
                    self.startBrowser()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func scheduleNext() {
        timer?.invalidate()
        let interval = answeredSinceActivation ? Self.pollInterval : Self.retryInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollNow()
                self?.scheduleNext()
            }
        }
    }

    private func pollNow() {
        endpoints.forEach(ask)
    }

    private func ask(_ endpoint: NWEndpoint) {
        let key = "\(endpoint)"
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let parameters = NWParameters.tcp
        // IPv4 only: a Bonjour peer also resolves to an IPv6 link-local address, which firewalls
        // (e.g. Little Snitch's "Local Network") commonly drop silently; a stalled IPv6 attempt
        // then decides whether a dispatch goes through. Everything here is on one LAN, so IPv4 always works.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        #if targetEnvironment(simulator)
        // The simulator shares the Mac's network stack; Bonjour may resolve to an interface
        // that can't reach the local relay, so stay on loopback.
        parameters.requiredInterfaceType = .loopback
        #endif
        let connection = NWConnection(to: endpoint, using: parameters)
        connections[key] = connection
        let session = self.session
        var finished = false
        let started = Date()
        Log.relay.info("Asking \(key, privacy: .public)")
        let finish: @MainActor (Bool, String) -> Void = { [weak self] answered, outcome in
            guard !finished else { return }
            finished = true
            let seconds = Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))
            Log.relay.info("\(key, privacy: .public): \(outcome, privacy: .public) after \(seconds, privacy: .public)s")
            connection.cancel()
            guard let self, self.session == session else { return }
            self.inFlight.remove(key)
            self.connections[key] = nil
            if answered, !self.answeredSinceActivation {
                self.answeredSinceActivation = true
                self.scheduleNext()
            }
            if answered, let onChecked = self.onChecked {
                self.onChecked = nil
                onChecked(true)
            }
        }
        connection.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                // Not reachable yet (no route while the network comes back): the next poll
                // tries again rather than this one waiting out its timeout.
                switch state {
                case .failed(let error): finish(false, "failed: \(error)")
                case .waiting(let error): finish(false, "unreachable: \(error)")
                case .ready:
                    let remote = connection.currentPath?.remoteEndpoint.map { "\($0)" } ?? "?"
                    Log.relay.info("\(key, privacy: .public): connected to \(remote, privacy: .public)")
                default: break
                }
            }
        }
        connection.start(queue: .main)
        // A Bonjour endpoint that can't be connected to (a stale address, a relay that's down)
        // can sit in `.preparing` indefinitely, retrying without ever reporting a failure, so
        // connecting gets a few seconds of its own.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if connection.state != .ready { finish(false, "couldn't connect (\(String(describing: connection.state)))") }
        }
        // Generous: a queue with full-size posters can take a while over Wi-Fi.
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) { finish(false, "timed out") }

        var request: [String: Any] = ["fetch": true]
        if let have = have() {
            request["have"] = have.date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            // Lets the relay tell a different queue with the same timestamp from the one held.
            request["haveFilms"] = have.filmIDs.map(\.uuidString)
        }
        let body = (try? JSONSerialization.data(withJSONObject: request)) ?? Data(#"{"fetch":true}"#.utf8)
        connection.send(content: Framing.frame(body), completion: .idempotent)
        Framing.receive(on: connection) { [weak self] body in
            guard let body, self?.session == session else { finish(false, "no reply"); return }
            let reply: QueueReply
            do {
                let payload = try JSONDecoder.atvq.decode(QueuePayload.self, from: body)
                if payload.version > QueuePayload.currentVersion {
                    reply = QueueReply(ok: false, error: "Unsupported version \(payload.version); update ATVQ")
                    Log.relay.error("Relay sent unsupported version \(payload.version)")
                } else {
                    Log.relay.info("Received a queue of \(payload.films.count) film(s) dispatched \(payload.dispatchedAt, privacy: .public)")
                    self?.onPayload?(payload)
                    reply = QueueReply(ok: true)
                }
            } catch {
                // The relay's "nothing newer held" reply is a QueueReply, not a payload.
                guard (try? JSONDecoder.atvq.decode(QueueReply.self, from: body)) == nil else { finish(true, "nothing newer held"); return }
                reply = QueueReply(ok: false, error: "Malformed payload: \(error)")
                Log.relay.error("Malformed payload from relay: \(String(describing: error), privacy: .public)")
            }
            let data = (try? JSONEncoder.atvq.encode(reply)) ?? Data()
            connection.send(content: Framing.frame(data), completion: .contentProcessed { _ in
                MainActor.assumeIsolated { finish(true, "delivered and confirmed") }
            })
        }
    }
}
