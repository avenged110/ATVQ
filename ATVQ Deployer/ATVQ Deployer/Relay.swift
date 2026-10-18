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
//   {"fetch":true, "have":…, "haveFilms":[…]}      → reply with the held payload if it's newer than
//                                                    `have` (ATVQ's newest) or has the same timestamp
//                                                    but other films, else {"ok":true};
//                                                    ATVQ then answers {"ok":true} once it has decoded it
// ATVQ polls with fetch every few seconds while it's on screen, so that is the dependable
// path; pushes only make a dispatch show up a little sooner.
//   {"ping":true}                                  → reply {"ok":true}, store nothing (FilmTracker's self-test)

import Foundation
import Network
import Observation

@Observable
final class Relay {
    private(set) var heldDispatchedAt: Date?
    private(set) var filmCount = 0
    /// The last queue handed off and then flushed (see flush): kept, without its bytes, so the
    /// status row can say where it went and an older or repeated dispatch isn't held again.
    private(set) var lastDelivered: (date: Date, filmCount: Int, to: String, at: Date)?
    @ObservationIgnored private var lastDeliveredFilmIDs: [String]?
    private(set) var isListening = false
    /// Bonjour actually published `_atvqrelay._tcp` (see startListener).
    private(set) var isAdvertised = false
    @ObservationIgnored var log: (String) -> Void = { _ in }

    private var held: Data?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var targets: [String: NWEndpoint] = [:]
    private var inFlight: Set<String> = []
    private var retryTimer: Timer?
    private var restartDelay: TimeInterval = 2
    private var restartPending = false
    /// ATVQ's address → its Bonjour name, learned from pushes, so a fetch from the same Apple TV
    /// is listed under the same name rather than a second time by address.
    private var peerNames: [String: String] = [:]
    /// The relay's usual port. A fixed port keeps a stale Bonjour record useful: an Apple TV
    /// that slept through a relay restart may still have the old service record cached, and with
    /// a port chosen afresh each start, that record pointed at nothing until it expired.
    static let preferredPort: NWEndpoint.Port = 52741
    /// Set when the preferred port couldn't be opened (e.g. another process holds it); the
    /// relay then takes any free port, which Bonjour still advertises. Cleared on wake and on
    /// each later restart, so the preferred port is tried again.
    private var preferredPortUnavailable = false
    /// A held dispatch dated further ahead than this is treated as a clock error (see accept).
    private static let futureSlack: TimeInterval = 10 * 60
    /// Pushes happen only for a short while after a dispatch arrives. A sleeping Apple TV
    /// can stay advertised through the network's Bonjour Sleep Proxy, and connecting to it
    /// can wake it — and, via HDMI-CEC, the home theater. Pushing indefinitely could do
    /// that all night. After the window, ATVQ's own fetch on launch/wake delivers the queue.
    private var pushUntil: Date?
    private static let pushWindow: TimeInterval = 10 * 60

    private static var fileURL: URL { Storage.directory.appendingPathComponent("relay-payload.json") }
    private static let lastDeliveredKey = "RelayLastDelivered"
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
        if let saved = UserDefaults.standard.dictionary(forKey: Self.lastDeliveredKey),
           let date = saved["date"] as? Date, let at = saved["at"] as? Date {
            lastDelivered = (date, saved["filmCount"] as? Int ?? 0, saved["to"] as? String ?? "ATVQ", at)
            lastDeliveredFilmIDs = saved["filmIDs"] as? [String]
        }
        startListener()
        startBrowser()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.forwardToAll() }
        }
    }

    // MARK: Listening for FilmTracker (and ATVQ fetches)

    private func startListener() {
        let parameters = NWParameters.tcp
        // Restarting reopens the same port right away; don't let the old socket's TIME_WAIT block it.
        parameters.allowLocalEndpointReuse = true
        let usesPreferredPort = !preferredPortUnavailable
        let created = usesPreferredPort
            ? try? NWListener(using: parameters, on: Self.preferredPort)
            : try? NWListener(using: parameters)
        guard let listener = created else {
            if usesPreferredPort { fallBackFromPreferredPort("couldn't create a listener on it"); return }
            scheduleRestart(); return
        }
        listener.service = NWListener.Service(type: "_atvqrelay._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    // The backoff resets once Bonjour publishes the service, not here: a
                    // listener that opens but is never advertised must keep backing off.
                    self?.isListening = true
                    let port = self?.listener?.port.map { "\($0)" } ?? "?"
                    self?.log("Relay listening on port \(port)\(usesPreferredPort ? "" : " (fallback; the usual port \(Self.preferredPort) is unavailable)").")
                case .failed(let error) where usesPreferredPort:
                    self?.fallBackFromPreferredPort("\(error)")
                case .failed(let error), .waiting(let error):
                    self?.isListening = false
                    self?.isAdvertised = false
                    self?.log("Relay listener: \(error); restarting.")
                    self?.scheduleRestart()
                default: break
                }
            }
        }
        // `.ready` only means the port is open. Whether Bonjour published the service is
        // reported here; without it FilmTracker can never find the relay.
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            MainActor.assumeIsolated {
                switch change {
                case .add(let endpoint):
                    self?.isAdvertised = true
                    self?.restartDelay = 2
                    self?.log("Relay advertised as \(endpoint).")
                case .remove:
                    // The listener stays `.ready` without it, so nothing else would ever bring
                    // the advertisement back: FilmTracker and ATVQ couldn't find the relay
                    // until the Deployer was relaunched. Start over to re-register.
                    self?.isAdvertised = false
                    self?.log("Relay advertisement withdrawn; re-registering.")
                    self?.scheduleRestart()
                @unknown default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.handle(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// The preferred port failed: open on any free port instead, at once.
    private func fallBackFromPreferredPort(_ reason: String) {
        log("Relay couldn't use port \(Self.preferredPort) (\(reason)); using another port.")
        stopListener()
        preferredPortUnavailable = true
        if !restartPending { startListener() }
    }

    private func scheduleRestart() {
        stopListener()
        preferredPortUnavailable = false
        guard !restartPending else { return }
        restartPending = true
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 120)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restartPending = false
            if self?.listener == nil { self?.startListener() }
        }
    }

    private func stopListener() {
        // Handlers first: cancelling reports the advertisement's removal, which mustn't
        // schedule another restart.
        listener?.stateUpdateHandler = nil
        listener?.serviceRegistrationUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        isListening = false
        isAdvertised = false
    }

    /// After the Mac wakes: the listener can stay `.ready` while its advertisement is gone, and
    /// the browser's view of which ATVQs exist is stale, so both start over.
    func restartNetworking() {
        guard retryTimer != nil else { return }   // not started
        log("Restarting the relay's network services after wake.")
        stopListener()
        restartDelay = 2
        preferredPortUnavailable = false
        if !restartPending { startListener() }
        stopBrowser()
        startBrowser()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        // Generous: a queue with full-size posters can take a while over Wi-Fi.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { connection.cancel() }
        Frames.receive(on: connection) { [weak self] body in
            guard let self, let body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                Self.reply(#"{"ok":false,"error":"Invalid frame"}"#, on: connection); return
            }
            if object["ping"] as? Bool == true {
                // FilmTracker's relay self-test: acknowledge, store nothing.
                self.log("Relay answered a test dispatch from FilmTracker.")
                Self.reply(#"{"ok":true}"#, on: connection); return
            }
            if object["fetch"] as? Bool == true {
                self.answerFetch(on: connection, have: (object["have"] as? String).flatMap(Self.date(from:)),
                                 haveFilms: object["haveFilms"] as? [String]); return
            }
            guard object["films"] != nil, let date = Self.dispatchedAt(in: body) else {
                Self.reply(#"{"ok":false,"error":"Not a queue payload"}"#, on: connection); return
            }
            Self.reply(#"{"ok":true}"#, on: connection)
            self.accept(body, dispatchedAt: date)
        }
    }

    /// Sends the held queue, then waits for ATVQ's {"ok":true}, so the log says whether it
    /// actually arrived rather than only that it was asked for.
    private func answerFetch(on connection: NWConnection, have: Date?, haveFilms: [String]?) {
        let address = Self.peerName(connection)
        let peer = peerNames[address] ?? address
        guard let held, let heldDispatchedAt else {
            Self.reply(#"{"ok":true}"#, on: connection); return
        }
        // ATVQ already has this queue (or a newer one): the usual poll, answered quietly.
        // A millisecond of slack: `have` has been through a date → text → date round trip.
        // The same timestamp with other films is a different queue (second-precision senders).
        let sameTime = have.map { abs(heldDispatchedAt.timeIntervalSince($0)) < 0.002 } ?? false
        let otherFilms = sameTime && Self.filmIDs(in: held).map { heldIDs in
            haveFilms.map { $0.map { $0.uppercased() } != heldIDs } ?? false
        } == true
        if let have, heldDispatchedAt.timeIntervalSince(have) < 0.002, !otherFilms {
            Self.reply(#"{"ok":true}"#, on: connection)
            // ATVQ has it (FilmTracker reached it directly, say): nothing left to hold for.
            log("ATVQ (\(peer)) already has the held queue.")
            flush(deliveredTo: peer)
            return
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(held.count), countStyle: .file)
        let dated = heldDispatchedAt.formatted(date: .abbreviated, time: .shortened)
        log("ATVQ (\(peer)) asked for the latest queue; sending the one dispatched \(dated) (\(size)).")
        connection.send(content: Frames.frame(held), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.log("Sending the queue to ATVQ (\(peer)) failed: \(error).") }
            connection.cancel()
        })
        Frames.receive(on: connection) { [weak self] reply in
            connection.cancel()
            guard let self else { return }
            let object = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if object?["ok"] as? Bool == true {
                self.log("ATVQ (\(peer)) confirmed it received the queue.")
                if self.held == held { self.flush(deliveredTo: peer) }
            } else if let error = object?["error"] as? String {
                self.log("ATVQ (\(peer)) rejected the queue: \(error)")
            } else {
                // Builds of ATVQ before the confirmation was added never reply; neither does a
                // transfer that broke off.
                self.log("ATVQ (\(peer)) didn't confirm receipt (connection closed or older ATVQ build).")
            }
        }
    }

    private static func peerName(_ connection: NWConnection) -> String {
        guard case .hostPort(let host, _) = connection.endpoint else { return "\(connection.endpoint)" }
        return address(of: host)
    }

    private static func address(of host: NWEndpoint.Host) -> String {
        let text = "\(host)"
        return text.split(separator: "%").first.map(String.init) ?? text   // drop IPv6 scope ID
    }

    private func accept(_ body: Data, dispatchedAt date: Date) {
        // Older, or the identical queue again, is ignored; a different queue with the same
        // (second-precision) timestamp is accepted.
        // A held queue dated well in the future came from a wrong clock on the sender's Mac;
        // honoring it would block every real queue (and stay saved) until time caught up.
        let heldImplausible = heldDispatchedAt.map { $0 > Date().addingTimeInterval(Self.futureSlack) } ?? false
        if let heldDispatchedAt, (date < heldDispatchedAt && !heldImplausible) || (date == heldDispatchedAt && body == held) {
            log("Relay ignored a queue no newer than the one held.")
            return
        }
        // Likewise against the queue already delivered and flushed: ATVQ would ignore it anyway.
        if heldDispatchedAt == nil, let last = lastDelivered, last.date <= Date().addingTimeInterval(Self.futureSlack),
           date < last.date || (date == last.date && Self.filmIDs(in: body) == lastDeliveredFilmIDs) {
            log("Relay ignored a queue no newer than the one already delivered.")
            return
        }
        held = body
        heldDispatchedAt = date
        filmCount = Self.filmCount(in: body)
        try? body.write(to: Self.fileURL, options: .atomic)
        pushUntil = Date().addingTimeInterval(Self.pushWindow)
        log("Relay received a queue of \(filmCount) film(s); forwarding.")
        forwardToAll()
    }

    /// ATVQ confirmed it has the held queue, so the relay's job is done: drop the payload (and
    /// its file) rather than hold it indefinitely, remembering only what went where.
    private func flush(deliveredTo name: String) {
        guard let held, let heldDispatchedAt else { return }
        let ids = Self.filmIDs(in: held)
        lastDelivered = (heldDispatchedAt, filmCount, name, Date())
        lastDeliveredFilmIDs = ids
        var saved: [String: Any] = ["date": heldDispatchedAt, "filmCount": filmCount, "to": name, "at": Date()]
        if let ids { saved["filmIDs"] = ids }
        UserDefaults.standard.set(saved, forKey: Self.lastDeliveredKey)
        self.held = nil
        self.heldDispatchedAt = nil
        filmCount = 0
        pushUntil = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
        log("Relay flushed the delivered queue.")
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
                self.forwardToAll()
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard case .failed = state, let self, self.browser === browser else { return }
                self.stopBrowser()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    if self?.browser == nil { self?.startBrowser() }
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func stopBrowser() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }

    private func forwardToAll() {
        guard let held, let pushUntil, Date() < pushUntil else { return }
        for (name, endpoint) in targets where !inFlight.contains(name) {
            forward(held, to: name, endpoint: endpoint)
        }
    }

    private func forward(_ body: Data, to name: String, endpoint: NWEndpoint) {
        inFlight.insert(name)
        let parameters = NWParameters.tcp
        // IPv4 only: a Bonjour peer also resolves to an IPv6 link-local address, which firewalls
        // (e.g. Little Snitch's "Local Network") commonly drop silently; a stalled IPv6 attempt
        // then decides whether a dispatch goes through. Everything here is on one LAN, so IPv4 always works.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        if loopbackOnly { parameters.requiredInterfaceType = .loopback }
        let connection = NWConnection(to: endpoint, using: parameters)
        var finished = false
        let finish: @MainActor (Bool, String) -> Void = { [weak self] ok, detail in
            guard !finished, let self else { return }
            finished = true
            connection.cancel()
            self.inFlight.remove(name)
            // Replaced while this was in flight: forwardToAll skipped this target then, so
            // send it the new queue now.
            if self.held != body { self.forwardToAll(); return }
            // Only count it if the queue wasn't replaced while this was in flight.
            if ok, self.held == body {
                self.log("Relay delivered the queue to \(name).")
                self.flush(deliveredTo: name)
            } else if !ok {
                self.log("Relay couldn't reach \(name) (\(detail)); will retry.")
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard case .ready = state, let remote = connection.currentPath?.remoteEndpoint,
                      case .hostPort(let host, _) = remote else { return }
                self?.peerNames[Self.address(of: host)] = name
            }
        }
        connection.start(queue: .main)
        // A Bonjour endpoint that can't be connected to can sit in `.preparing` indefinitely
        // without reporting a failure; don't let it hold this target for the full timeout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if connection.state != .ready { finish(false, "couldn't connect") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { finish(false, "timed out") }
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
        return date(from: text)
    }

    private static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    /// The films' IDs, uppercased (as ATVQ sends them); nil if any film has none, since ATVQ
    /// then makes one up and the lists could never match.
    private static func filmIDs(in body: Data) -> [String]? {
        guard let films = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["films"] as? [[String: Any]] else { return nil }
        let ids = films.compactMap { ($0["id"] as? String)?.uppercased() }
        return ids.count == films.count ? ids : nil
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
