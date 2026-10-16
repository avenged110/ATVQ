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
        #if targetEnvironment(simulator)
        // The simulator shares the Mac's network stack; Bonjour may resolve to an interface
        // that can't reach the local relay, so stay on loopback.
        parameters.requiredInterfaceType = .loopback
        #endif
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { connection.cancel() }
        connection.send(content: Framing.frame(Data(#"{"fetch":true}"#.utf8)), completion: .idempotent)
        Framing.receive(on: connection) { [weak self] body in
            connection.cancel()
            guard let body, let payload = try? JSONDecoder.atvq.decode(QueuePayload.self, from: body) else { return }
            self?.onPayload?(payload)
        }
    }
}
