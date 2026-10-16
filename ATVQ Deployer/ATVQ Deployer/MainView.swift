// MARK: - MainView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// One fixed-size pane of settings cards: status, target, schedule, alerts, and the live log.
// The card and row styling follows CalShare's settings tables; the steppers follow Film Tracker's.

import SwiftUI

enum Layout {
    static let windowWidth: CGFloat = 640
    /// The text fields' and the Apple TV picker's width in the trailing column.
    static let fieldWidth: CGFloat = 300
    static let logHeight: CGFloat = 170
    /// About half the cards' full height; the cards scroll within it.
    static let windowHeight: CGFloat = 560
    /// The trailing column the status glyphs sit in, so their rows align.
    static let glyphWidth: CGFloat = 20
}

struct MainView: View {
    @Bindable var deployer: Deployer

    var body: some View {
        ScrollView {
            cards
        }
        .frame(width: Layout.windowWidth, height: Layout.windowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 16) {
            TableSection("Status") {
                TableRow("Provisioning profile") {
                    HStack(spacing: 6) {
                        if deployer.isRunning { ProgressView().controlSize(.small) }
                        Text(deployer.statusLine)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        StatusGlyph(systemName: deployer.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                    color: deployer.isHealthy ? .green : .orange)
                    }
                }
                TableRow("Queue relay") {
                    RelayStatus(relay: deployer.relay)
                }
                HStack {
                    Spacer()
                    Button("Open Logs") { NSWorkspace.shared.open(Storage.logsDirectory) }
                    Button("Refresh Now") { deployer.refresh(trigger: "manual") }
                        .keyboardShortcut("r")
                        .disabled(deployer.isRunning || deployer.isPulling)
                }
            }

            TableSection("Target") {
                TableRow("Project") {
                    HStack {
                        Text(deployer.config.projectPath.isEmpty ? "None" : deployer.config.projectPath)
                            .lineLimit(1).truncationMode(.head)
                            .foregroundStyle(deployer.config.projectPath.isEmpty ? .secondary : .primary)
                            .help(deployer.config.projectPath)
                        Button("Choose…", action: chooseProject)
                    }
                    .frame(maxWidth: Layout.fieldWidth + 80, alignment: .trailing)
                }
                TableRow("Source", note: "Pulls the latest version of the whole project folder from GitHub.") {
                    HStack {
                        if !deployer.pullStatus.isEmpty {
                            Text(deployer.pullStatus)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        if deployer.isPulling { ProgressView().controlSize(.small) }
                        Button("Pull Latest") { deployer.pullLatest() }
                            .disabled(deployer.isPulling || deployer.isRunning || deployer.config.projectPath.isEmpty)
                    }
                }
                TableRow("Scheme") { field($deployer.config.scheme) }
                TableRow("Bundle ID") { field($deployer.config.bundleID) }
                TableRow("Team ID") { field($deployer.config.teamID, prompt: "Optional: uses the project's team") }
                TableRow("Apple TV") {
                    HStack {
                        Picker("Apple TV", selection: $deployer.config.deviceID) {
                            Text("None").tag("")
                            ForEach(deployer.devices) { device in
                                Text("\(device.name) — \(device.detail)").tag(device.id)
                            }
                            if !deployer.config.deviceID.isEmpty, !deployer.devices.contains(where: { $0.id == deployer.config.deviceID }) {
                                Text("\(deployer.config.deviceName) (not currently listed)").tag(deployer.config.deviceID)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .onChange(of: deployer.config.deviceID) { _, id in
                            if let device = deployer.devices.first(where: { $0.id == id }) { deployer.config.deviceName = device.name }
                        }
                        Button("Rescan") { Task { await deployer.refreshDevices() } }
                            .fixedSize()
                    }
                    // The picker takes what the button leaves, so the row matches the fields above
                    // and a long device name can't squeeze the button.
                    .frame(width: Layout.fieldWidth)
                }
            }

            TableSection("Schedule") {
                TableRow("Refresh when remaining time drops below") {
                    ValueStepper(value: $deployer.config.thresholdHours, in: 24...144, step: 12, unit: "hours")
                }
                TableRow("Check the profile every") {
                    ValueStepper(value: $deployer.config.checkIntervalMinutes, in: 5...60, step: 5, unit: "min")
                        .onChange(of: deployer.config.checkIntervalMinutes) { deployer.scheduleTimer() }
                }
                TableCheckbox("Pull latest source before building", note: "Runs git pull --ff-only in the project's folder.",
                              isOn: $deployer.config.gitPull)
                TableCheckbox("Launch ATVQ after installing", note: "This can wake the Apple TV, and the TV and receiver through HDMI-CEC.",
                              isOn: $deployer.config.launchAfterInstall)
                TableCheckbox("Launch at login", isOn: Binding(get: { deployer.launchesAtLogin },
                                                              set: { deployer.launchesAtLogin = $0 }))
            }

            TableSection("Alerts") {
                TableRow("ntfy URL") {
                    HStack {
                        TextField("ntfy URL", text: $deployer.config.ntfyURL, prompt: Text("https://ntfy.sh/your-secret-topic"))
                            .labelsHidden()
                            .frame(width: Layout.fieldWidth - 90)
                        Button("Test Alert") {
                            deployer.sendAlert(title: "ATVQ Deployer test", message: deployer.statusLine, urgent: false)
                        }
                        .disabled(deployer.config.ntfyURL.isEmpty)
                    }
                }
            }

            TableSection("Console") {
                LogView(lines: deployer.log)
                    .frame(height: Layout.logHeight)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
    }

    private func field(_ text: Binding<String>, prompt: String? = nil) -> some View {
        TextField("", text: text, prompt: prompt.map { Text($0) })
            .labelsHidden()
            .frame(width: Layout.fieldWidth)
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        // No allowedContentTypes: `UTType(filenameExtension: "xcodeproj")` yields a dynamic type
        // that Xcode's registered project type doesn't conform to, which disabled every item.
        // The delegate enables folders (to navigate) and .xcodeproj packages instead.
        let filter = XcodeProjectFilter()
        panel.delegate = filter
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose ATVQ.xcodeproj"
        if !deployer.config.projectPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: deployer.config.projectPath).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url, url.pathExtension == "xcodeproj" {
            deployer.config.projectPath = url.path
        }
        withExtendedLifetime(filter) {}
    }
}

/// Enables only folders and Xcode project packages in the project picker.
private final class XcodeProjectFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if url.pathExtension == "xcodeproj" { return true }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}

// MARK: - Tables (after CalShare's SharedViews)

/// A titled card of rows divided by separators.
private struct TableSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.horizontal, 12) }
                        row
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .cardChrome()
        }
    }
}

/// The label leading, the control trailing; a note under the label makes the row taller.
private struct TableRow<Control: View>: View {
    let label: String
    var note: String?
    let control: Control

    init(_ label: String, note: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.note = note
        self.control = control()
    }

    var body: some View {
        HStack(alignment: note == nil ? .firstTextBaseline : .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

private struct TableCheckbox: View {
    let title: String
    var note: String?
    @Binding var isOn: Bool

    init(_ title: String, note: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        self._isOn = isOn
    }

    var body: some View {
        TableRow(title, note: note) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
    }
}

/// A stepper with its value and unit inside the control, in Film Tracker's stepper chrome.
private struct ValueStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String) {
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            Text("\(Int(value)) \(unit)")
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
                .contentTransition(.identity)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(stepperFill))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .quaternaryLabelColor), lineWidth: 1))
    }
}

/// Film Tracker's stepper fill: the under-page color in dark mode, a light gray in light mode.
private let stepperFill = Color(NSColor(name: nil) { appearance in
    var resolved = NSColor.underPageBackgroundColor
    appearance.performAsCurrentDrawingAppearance {
        resolved = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.underPageBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor
    }
    return resolved
})

private extension View {
    /// CalShare's card chrome: the control background, an outline that fades down the
    /// shape, and a soft shadow cast by the fill alone.
    func cardChrome() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let separator = Color(nsColor: .separatorColor)
        let border = LinearGradient(
            stops: [.init(color: separator.opacity(0.2), location: 0),
                    .init(color: separator.opacity(0.2), location: 0.1),
                    .init(color: separator.opacity(0), location: 1)],
            startPoint: .top, endPoint: .bottom)
        return background {
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.16), radius: 1.5, x: 0, y: 1)
        }
        .overlay(shape.strokeBorder(border, lineWidth: 1))
    }
}

// MARK: - Status and log

private struct RelayStatus: View {
    let relay: Relay

    var body: some View {
        HStack(spacing: 6) {
            Text(summary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            StatusGlyph(systemName: relay.isListening ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                        color: relay.isListening ? .green : .orange)
        }
    }

    private var summary: String {
        guard let date = relay.heldDispatchedAt else {
            return relay.isListening ? "Listening, no queue held" : "Not listening"
        }
        let held = "Holding \(relay.filmCount) film(s) from \(date.formatted(date: .abbreviated, time: .shortened))"
        guard !relay.deliveries.isEmpty else { return held + ", not yet delivered" }
        let names = relay.deliveries.sorted { $0.value > $1.value }
            .map { "\($0.key) at \($0.value.formatted(date: .omitted, time: .shortened))" }
        return held + ", delivered to " + names.joined(separator: ", ")
    }
}

/// A status glyph centered in the fixed trailing column.
private struct StatusGlyph: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(color)
            .frame(width: Layout.glyphWidth)
    }
}

private struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index]).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
        }
    }
}
