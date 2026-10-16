// MARK: - DeployerApp.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Menu bar app that keeps ATVQ installed on the Apple TV by re-signing it before the
// free Personal Team profile expires.

import SwiftUI

@main
struct DeployerApp: App {
    @State private var deployer = Deployer()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(deployer: deployer)
        } label: {
            Image(systemName: deployer.isRunning ? "arrow.triangle.2.circlepath"
                  : deployer.isHealthy ? "appletv" : "exclamationmark.triangle")
                .task { deployer.start() }
        }

        Window("ATVQ Deployer", id: "main") {
            MainView(deployer: deployer)
                // A background, so the zero-size probe never takes a click.
                .background(MainWindowConfigurator())
        }
        // The window takes MainView's fixed frame; MainWindowConfigurator makes zoom inert.
        .windowResizability(.contentSize)
    }
}

private struct MenuContent: View {
    let deployer: Deployer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(deployer.statusLine)
        if let due = deployer.refreshDue, !deployer.isRunning {
            Text("Next refresh \(due.formatted(date: .abbreviated, time: .shortened))")
        }
        Divider()
        Button("Refresh Now") { deployer.refresh(trigger: "manual") }
            .disabled(deployer.isRunning)
        Button("Open ATVQ Deployer…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

// MARK: - MainWindowConfigurator

/// Fixes the window at its content's size, after CalShare's configurator.
/// `.windowResizability(.contentSize)` fixes the size but leaves the zoom button live, so this
/// clears the `.resizable` mask (AppKit then disables zoom itself), and keeps clearing it,
/// since SwiftUI puts it back whenever the content's size range changes. Full screen and
/// tabbing are turned off too.
private struct MainWindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        var styleMaskObservation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowProbeView {
        let probe = WindowProbeView(frame: .zero)
        let coordinator = context.coordinator
        probe.onAttach = { configure($0, coordinator) }
        return probe
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        configure(nsView.hostWindow, context.coordinator)
    }

    @MainActor
    private func configure(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard let window else { return }
        if coordinator.styleMaskObservation == nil {
            coordinator.styleMaskObservation = window.observe(\.styleMask) { window, _ in
                MainActor.assumeIsolated {
                    if window.styleMask.contains(.resizable) { window.styleMask.remove(.resizable) }
                }
            }
        }
        window.styleMask.remove(.resizable)
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
        window.tabbingMode = .disallowed
    }
}

/// Zero-size view whose only job is to report the moment it is attached to a window.
private final class WindowProbeView: NSView {
    var onAttach: ((NSWindow) -> Void)?
    private(set) weak var hostWindow: NSWindow?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        hostWindow = newWindow
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let hostWindow { onAttach?(hostWindow) }
    }
}
