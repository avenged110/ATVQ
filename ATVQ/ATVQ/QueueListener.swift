// MARK: - QueueListener.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Advertises ATVQ over Bonjour and accepts queue dispatches from FilmTracker.
// ATVQ is the server so FilmTracker only ever needs an outgoing (client) connection.

import Foundation
import Network
import os

final class QueueListener {
    static let serviceType = "_atvq._tcp"

    private var listener: NWListener?
    private var onReceive: ((QueuePayload) -> Void)?
    private var retryDelay: TimeInterval = 1

    func start(onReceive: @escaping (QueuePayload) -> Void) {
        guard listener == nil else { return }
        self.onReceive = onReceive
        startListener()
    }

    private func startListener() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        guard let listener = try? NWListener(using: parameters) else { scheduleRestart(); return }
        // nil name: Bonjour uses the Apple TV's own name, e.g. "Living Room".
        listener.service = NWListener.Service(type: Self.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                Log.listener.info("Listener: \(String(describing: state), privacy: .public)")
                switch state {
                case .ready: self?.retryDelay = 1
                // .waiting means the network went away (e.g. Wi-Fi dropped); start over
                // rather than trusting the old advertisement to come back by itself.
                case .failed, .waiting: self?.scheduleRestart()
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

    /// Called whenever the app returns to the foreground. Always starts over: while ATVQ
    /// was suspended, tvOS may have reclaimed the listening socket and withdrawn the Bonjour
    /// advertisement without the listener ever leaving `.ready`, which left ATVQ open on
    /// screen but unreachable.
    func restart() {
        guard onReceive != nil else { return }
        stop()
        retryDelay = 1
        startListener()
    }

    /// Called when the app leaves the foreground.
    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private var restartPending = false

    private func scheduleRestart() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        guard !restartPending else { return }
        restartPending = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restartPending = false
            self?.startListener()   // no-op if restart() already restarted it
        }
    }

    // MARK: Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        // A sender that connects and stalls must not hold the connection open forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if connection.state != .cancelled { connection.cancel() }
        }
        Framing.receive(on: connection) { [weak self] body in
            guard let self, let body else {
                self?.reply(QueueReply(ok: false, error: "Invalid frame"), on: connection); return
            }
            do {
                let payload = try JSONDecoder.atvq.decode(QueuePayload.self, from: body)
                guard payload.version <= QueuePayload.currentVersion else {
                    self.reply(QueueReply(ok: false, error: "Unsupported version \(payload.version); update ATVQ"), on: connection); return
                }
                Log.listener.info("Direct dispatch of \(payload.films.count) film(s) dispatched \(payload.dispatchedAt, privacy: .public)")
                self.onReceive?(payload)
                self.reply(QueueReply(ok: true), on: connection)
            } catch {
                self.reply(QueueReply(ok: false, error: "Malformed payload: \(error)"), on: connection)
            }
        }
    }

    private func reply(_ reply: QueueReply, on connection: NWConnection) {
        let body = (try? JSONEncoder.atvq.encode(reply)) ?? Data()
        connection.send(content: Framing.frame(body), completion: .contentProcessed { _ in connection.cancel() })
    }
}
