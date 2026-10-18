// MARK: - ATVQApp.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// App entry point. Owns the queue store, the listener for direct dispatches, and the
// relay poller; both networking pieces run only while ATVQ is in the foreground.

import SwiftUI

@main
struct ATVQApp: App {
    @State private var store = QueueStore()
    @State private var listener = QueueListener()
    @State private var relay = RelayClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(.dark)
                .onAppear {
                    listener.start { payload in store.apply(payload) }
                    startRelay()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-ATVQSample") { store.apply(SampleData.payload(), persist: false) }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        listener.restart()
                        startRelay()
                    case .background:
                        listener.stop()
                        relay.stop()
                    default:
                        break
                    }
                }
        }
    }

    private func startRelay() {
        store.refreshStarted()
        relay.start(have: { store.newestHeld },
                    onPayload: { payload in store.apply(payload) },
                    onChecked: { reached in store.refreshFinished(reachedRelay: reached) })
    }
}
