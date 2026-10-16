// MARK: - ATVQApp.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// App entry point. Owns the queue store and starts the network listener.

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
                    relay.fetch { payload in store.apply(payload) }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-ATVQSample") { store.apply(SampleData.payload(), persist: false) }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    listener.ensureRunning()
                    relay.fetch { payload in store.apply(payload) }
                }
        }
    }
}
