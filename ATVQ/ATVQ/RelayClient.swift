// MARK: - RelayClient.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Asks the ATVQ Deployer relay (on the always-on Mac) for the latest queue whenever ATVQ
// launches or returns to the foreground, so a dispatch sent while the Apple TV slept is
// picked up on wake. Direct pushes (from FilmTracker or the relay) still arrive through
// QueueListener; the store keeps whichever payload is newest.
//
// Request:  framed JSON {"fetch": true}
// Response: framed QueuePayload, or framed QueueReply when the relay holds nothing.
// After a payload, ATVQ answers with a framed QueueReply so the relay can log delivery.

import Foundation
import Network

final class RelayClient {
    static let serviceType = "_atvqrelay._tcp"

    private var browser: NWBrowser?
    private var asked: Set<String> = []
    private var onPayload: ((QueuePayload) -> Void)?

    func fetch(onPayload: @escaping (QueuePayload) -> Void) {
        self.onPayload = onPayload
        browser?.cancel()
        asked.removeAll()
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { results.forEach { self?.ask($0.endpoint) } }
        }
        browser.start(queue: .main)
        self.browser = browser
        // Discovery is only needed briefly; pushes cover the rest of the session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak browser] in
            browser?.cancel()
            if self?.browser === browser { self?.browser = nil }
        }
    }

    private func ask(_ endpoint: NWEndpoint) {
        let key = "\(endpoint)"
        guard !asked.contains(key) else { return }
        asked.insert(key)
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
        connection.start(queue: .main)
        // Generous: a queue with full-size posters can take a while over Wi-Fi.
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) { connection.cancel() }
        connection.send(content: Framing.frame(Data(#"{"fetch":true}"#.utf8)), completion: .idempotent)
        Framing.receive(on: connection) { [weak self] body in
            guard let body else { connection.cancel(); return }
            let reply: QueueReply
            do {
                let payload = try JSONDecoder.atvq.decode(QueuePayload.self, from: body)
                if payload.version > QueuePayload.currentVersion {
                    reply = QueueReply(ok: false, error: "Unsupported version \(payload.version); update ATVQ")
                } else {
                    self?.onPayload?(payload)
                    reply = QueueReply(ok: true)
                }
            } catch {
                // The relay's "nothing held" reply is a QueueReply, not a payload.
                guard (try? JSONDecoder.atvq.decode(QueueReply.self, from: body)) == nil else { connection.cancel(); return }
                reply = QueueReply(ok: false, error: "Malformed payload: \(error)")
            }
            let data = (try? JSONEncoder.atvq.encode(reply)) ?? Data()
            connection.send(content: Framing.frame(data), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
