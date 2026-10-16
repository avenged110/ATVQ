// MARK: - Deployer.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Scheduler and refresh pipeline: build → read expiry → install → launch.
// Checks periodically (and on wake) whether the profile is inside the refresh window,
// rather than sleeping until a single far-off deadline.

import AppKit
import Observation
import ServiceManagement

@Observable
final class Deployer {
    var config: DeployConfig {
        didSet {
            guard config != oldValue else { return }
            Storage.save(config, "config.json")
            // A different project, app or device: the recorded expiry no longer describes what's installed.
            if config.target != oldValue.target, !isRunning {
                state.expiry = nil
                state.nextRetry = nil
                Storage.save(state, "state.json")
            }
        }
    }
    private(set) var state: DeployState
    private(set) var log: [String] = []
    private(set) var isRunning = false
    private(set) var devices: [TVDevice] = []
    private(set) var currentStage = ""
    let relay = Relay()

    private var timer: Timer?
    private var logHandle: FileHandle?
    private static let maxLogLines = 5000
    private static let keptLogFiles = 40

    init() {
        config = Storage.load(DeployConfig.self, "config.json") ?? DeployConfig()
        state = Storage.load(DeployState.self, "state.json") ?? DeployState()
    }

    // MARK: Scheduling

    func start() {
        guard timer == nil else { return }
        appendLog("ATVQ Deployer started.")
        relay.log = { [weak self] line in self?.appendLog(line) }
        relay.start()
        scheduleTimer()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appendLog("Woke from sleep; checking.")
                // Give the network a moment to come back before touching the device.
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self?.check(trigger: "wake") }
            }
        }
        Task { await refreshDevices() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check(trigger: "launch") }
    }

    func scheduleTimer() {
        timer?.invalidate()
        let interval = max(config.checkIntervalMinutes, 5) * 60
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(trigger: "timer") }
        }
        timer.tolerance = 60
        // .common so checks still fire while the menu bar menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var refreshDue: Date? {
        if let retry = state.nextRetry { return retry }
        guard let expiry = state.expiry else { return nil }
        return expiry.addingTimeInterval(-config.thresholdHours * 3600)
    }

    func check(trigger: String) {
        guard !isRunning else { return }
        if let expiry = state.expiry, expiry < Date().addingTimeInterval(24 * 3600), state.consecutiveFailures > 0 {
            // Inside the last day with a failing refresh: keep pressing, every check.
            refresh(trigger: "\(trigger) (urgent)")
            return
        }
        guard let due = refreshDue else {
            if state.expiry == nil, isConfigured { refresh(trigger: "\(trigger) (no known expiry)") }
            return
        }
        if Date() >= due { refresh(trigger: trigger) }
    }

    var isConfigured: Bool {
        !config.projectPath.isEmpty && !config.scheme.isEmpty && !config.bundleID.isEmpty && !config.deviceID.isEmpty
    }

    // MARK: Devices

    func refreshDevices() async {
        let found = await Tools.listDevices { line in Task { @MainActor in self.appendLog(line, verbose: true) } }
        devices = found
        if let match = found.first(where: { $0.id == config.deviceID }), match.name != config.deviceName {
            config.deviceName = match.name
        }
        appendLog("Found \(found.count) tvOS device(s).")
    }

    // MARK: Pipeline

    func refresh(trigger: String) {
        guard !isRunning else { return }
        isRunning = true
        let started = Date()
        let logURL = openRunLog(started)
        appendLog("── Refresh started (\(trigger)) ──")

        Task {
            let failure = await runPipeline()
            finish(started: started, trigger: trigger, failure: failure, logURL: logURL)
        }
    }

    /// Returns nil on success, or the failure and a one-line reason.
    private func runPipeline() async -> (FailureKind, String)? {
        // One snapshot per run, so editing settings mid-run can't mix two configurations.
        let config = self.config
        guard isConfigured else { return (.configuration, "Project, scheme, bundle ID and device must all be set.") }
        let project = URL(fileURLWithPath: config.projectPath)
        let projectDir = project.deletingLastPathComponent()
        let sink: @Sendable (String) -> Void = { line in Task { @MainActor in self.appendLog(line) } }
        let previousExpiry = state.expiry
        let renewalDeadline = Date().addingTimeInterval(config.thresholdHours * 3600)

        if config.gitPull {
            stage("Pulling latest source")
            let pull = await ProcessRunner.run("/usr/bin/git", ["pull", "--ff-only"], in: projectDir, timeout: 300, onLine: sink)
            if !pull.succeeded { appendLog("git pull failed; building the existing checkout.") }
        }

        // Xcode reuses a cached profile until it actually expires, so a profile inside the
        // refresh window is moved aside to make -allowProvisioningUpdates fetch a fresh one.
        // It's put back if the build fails (still better than nothing) and deleted on success.
        stage("Retiring expiring provisioning profiles")
        let retired = retireProfiles(await Tools.expiringProfiles(for: config.bundleID, before: renewalDeadline))

        stage("Building")
        var buildArgs = ["xcodebuild", "-project", project.path, "-scheme", config.scheme,
                         "-destination", "generic/platform=tvOS", "-configuration", "Debug",
                         "-derivedDataPath", Storage.derivedData.path, "-allowProvisioningUpdates", "build"]
        if !config.teamID.isEmpty { buildArgs.append("DEVELOPMENT_TEAM=\(config.teamID)") }
        let build = await ProcessRunner.run(Tools.xcrun, buildArgs, in: projectDir, timeout: 45 * 60, onLine: sink)
        guard build.succeeded else {
            restoreProfiles(retired)
            let kind = Tools.classify(build.output, stage: .build)
            return (kind, build.timedOut ? "xcodebuild timed out." : "xcodebuild exited with \(build.status).")
        }
        discardProfiles(retired)

        let products = Storage.derivedData.appendingPathComponent("Build/Products/Debug-appletvos")
        guard let app = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else {
            return (.build, "Build succeeded but no .app was found in \(products.path).")
        }

        stage("Reading profile expiry")
        let expiry = await Tools.profileExpiry(appURL: app)
        if let expiry { appendLog("Provisioning profile expires \(expiry.formatted(date: .abbreviated, time: .shortened)).") }
        else { appendLog("Could not read the profile expiry.") }

        stage("Installing on \(config.deviceName.isEmpty ? "Apple TV" : config.deviceName)")
        let install = await ProcessRunner.run(Tools.xcrun, ["devicectl", "device", "install", "app", "--device", config.deviceID, app.path],
                                              timeout: 15 * 60, onLine: sink)
        guard install.succeeded else {
            return (Tools.classify(install.output, stage: .install), "Install exited with \(install.status).")
        }
        // Record the expiry only after a successful install: the build's profile is what's on the TV now.
        state.expiry = expiry

        if config.launchAfterInstall {
            stage("Launching")
            let launch = await ProcessRunner.run(Tools.xcrun, ["devicectl", "device", "process", "launch", "--device", config.deviceID, config.bundleID],
                                                 timeout: 120, onLine: sink)
            if !launch.succeeded { appendLog("Launch failed (non-fatal; the app is installed).") }
        }

        // A renewal was due but the profile didn't move: retrying every check would loop
        // without ever extending it, so report it as a signing problem (alerts, backs off).
        if let previousExpiry, previousExpiry < renewalDeadline, let expiry, expiry <= previousExpiry.addingTimeInterval(3600) {
            return (.signing, "Installed, but the provisioning profile was not renewed (still expires \(expiry.formatted(date: .abbreviated, time: .shortened))).")
        }
        return nil
    }

    // MARK: Profile retirement

    private func retireProfiles(_ files: [URL]) -> [(original: URL, backup: URL)] {
        let backupDir = Storage.directory.appendingPathComponent("RetiredProfiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        return files.compactMap { file in
            let backup = backupDir.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: file, to: backup)
                appendLog("Moved aside expiring profile \(file.lastPathComponent).")
                return (file, backup)
            } catch {
                appendLog("Couldn't move aside \(file.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }
    }

    private func restoreProfiles(_ retired: [(original: URL, backup: URL)]) {
        for (original, backup) in retired where !FileManager.default.fileExists(atPath: original.path) {
            try? FileManager.default.moveItem(at: backup, to: original)
        }
        discardProfiles(retired)
    }

    private func discardProfiles(_ retired: [(original: URL, backup: URL)]) {
        retired.forEach { try? FileManager.default.removeItem(at: $0.backup) }
    }

    private func finish(started: Date, trigger: String, failure: (FailureKind, String)?, logURL: URL?) {
        let previousFailures = state.consecutiveFailures
        if let (kind, message) = failure {
            state.consecutiveFailures += 1
            state.lastFailure = kind
            // 5 min, 10, 20 … capped at 3 h.
            let backoff = min(5 * 60 * pow(2, Double(state.consecutiveFailures - 1)), 3 * 3600)
            state.nextRetry = Date().addingTimeInterval(backoff)
            appendLog("✗ \(kind.rawValue): \(message) Retrying \(state.nextRetry!.formatted(date: .omitted, time: .shortened)).")
            let shouldAlert = kind.needsAttention || state.consecutiveFailures >= 3
                || (state.expiry.map { $0 < Date().addingTimeInterval(36 * 3600) } ?? false)
            if shouldAlert, state.alertedFailure != kind {
                state.alertedFailure = kind
                sendAlert(title: "ATVQ refresh failed: \(kind.rawValue)",
                          message: "\(message)\n\(expiryDescription). Failures in a row: \(state.consecutiveFailures).",
                          urgent: true)
            }
        } else {
            state.consecutiveFailures = 0
            // Installed, but the expiry is unknown: don't rebuild every check; look again in 6 h
            // and say so once, since unattended scheduling depends on that date.
            state.nextRetry = state.expiry == nil ? Date().addingTimeInterval(6 * 3600) : nil
            if state.expiry == nil {
                if state.alertedUnknownExpiry != true {
                    state.alertedUnknownExpiry = true
                    sendAlert(title: "ATVQ installed, expiry unknown",
                              message: "Couldn't read the provisioning profile's expiry. Rechecking every 6 hours.", urgent: false)
                }
            } else {
                state.alertedUnknownExpiry = nil
            }
            state.lastFailure = nil
            state.lastSuccess = Date()
            appendLog("✓ Refresh complete. \(expiryDescription).")
            if previousFailures > 0, state.alertedFailure != nil {
                sendAlert(title: "ATVQ refresh recovered", message: "\(expiryDescription).", urgent: false)
            }
            state.alertedFailure = nil
        }
        state.history.insert(RunRecord(started: started, finished: Date(), trigger: trigger, failure: failure?.0,
                                       message: failure?.1 ?? "OK", logFile: logURL?.lastPathComponent ?? ""), at: 0)
        state.history = Array(state.history.prefix(100))
        Storage.save(state, "state.json")
        try? logHandle?.close()
        logHandle = nil
        currentStage = ""
        isRunning = false
    }

    private func stage(_ name: String) {
        currentStage = name
        appendLog("▸ \(name)…")
    }

    func sendAlert(title: String, message: String, urgent: Bool) {
        guard !config.ntfyURL.isEmpty else { appendLog("(No alert URL configured: \(title))"); return }
        let url = config.ntfyURL
        Task {
            let ok = await Tools.alert(url, title: title, message: message, urgent: urgent)
            appendLog(ok ? "Alert sent: \(title)" : "Alert FAILED to send: \(title)")
        }
    }

    // MARK: Status

    var expiryDescription: String {
        guard let expiry = state.expiry else { return "Expiry unknown" }
        let remaining = expiry.timeIntervalSinceNow
        if remaining <= 0 { return "EXPIRED \(expiry.formatted(date: .abbreviated, time: .shortened))" }
        let days = Int(remaining / 86400), hours = Int(remaining.truncatingRemainder(dividingBy: 86400) / 3600)
        return "Expires in \(days)d \(hours)h"
    }

    var statusLine: String {
        if isRunning { return "Refreshing: \(currentStage)" }
        var parts = [expiryDescription]
        if let failure = state.lastFailure { parts.append("last refresh FAILED (\(failure.rawValue), \(state.consecutiveFailures)×)") }
        else if state.lastSuccess != nil { parts.append("last refresh OK") }
        return parts.joined(separator: ", ")
    }

    var isHealthy: Bool { state.lastFailure == nil && (state.expiry.map { $0 > Date() } ?? false) }

    // MARK: Login item

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                appendLog("Login item change failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Logging

    /// xcodebuild can emit thousands of lines a second; lines are batched into the
    /// observable log a few times a second so SwiftUI isn't re-rendered per line.
    private var pendingLines: [String] = []
    private var flushScheduled = false

    func appendLog(_ line: String, verbose: Bool = false) {
        let stamped = "[\(Date().formatted(date: .omitted, time: .standard))] \(line)"
        try? logHandle?.write(contentsOf: Data((stamped + "\n").utf8))
        guard !verbose else { return }
        pendingLines.append(stamped)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.flushLog() }
    }

    private func flushLog() {
        flushScheduled = false
        log.append(contentsOf: pendingLines)
        pendingLines.removeAll(keepingCapacity: true)
        // Trim in chunks rather than per line (removeFirst is O(n)).
        if log.count > Self.maxLogLines + 500 { log.removeFirst(log.count - Self.maxLogLines) }
    }

    private func openRunLog(_ date: Date) -> URL? {
        let name = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-") + ".log"
        let url = Storage.logsDirectory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
        // Keep only the newest run logs.
        if let files = try? FileManager.default.contentsOfDirectory(at: Storage.logsDirectory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            files.dropFirst(Self.keptLogFiles).forEach { try? FileManager.default.removeItem(at: $0) }
        }
        return url
    }
}
