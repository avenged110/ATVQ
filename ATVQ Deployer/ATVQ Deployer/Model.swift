// MARK: - Model.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Persisted configuration and state, stored as JSON in Application Support.

import Foundation

struct DeployConfig: Codable, Equatable {
    var projectPath = ""            // the .xcodeproj
    var scheme = "ATVQ"
    var bundleID = "app.ATVQ"
    var teamID = ""                 // optional DEVELOPMENT_TEAM override (Personal Team ID)
    var deviceID = ""               // devicectl identifier
    var deviceName = ""
    var thresholdHours = 48.0       // refresh when less than this remains
    var checkIntervalMinutes = 20.0
    var gitPull = false             // fetch + reset to GitHub before building
    var ntfyURL = ""                // e.g. https://ntfy.sh/your-secret-topic
    var launchAfterInstall = false  // launching can wake the Apple TV (and, via HDMI-CEC, the TV/receiver)

    init() {}

    /// Tolerant decoding: a setting added in a later version falls back to its default
    /// instead of failing the whole file (which would silently reset every setting).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeployConfig()
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath) ?? d.projectPath
        scheme = try c.decodeIfPresent(String.self, forKey: .scheme) ?? d.scheme
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? d.bundleID
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID) ?? d.teamID
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? d.deviceID
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? d.deviceName
        thresholdHours = try c.decodeIfPresent(Double.self, forKey: .thresholdHours) ?? d.thresholdHours
        checkIntervalMinutes = try c.decodeIfPresent(Double.self, forKey: .checkIntervalMinutes) ?? d.checkIntervalMinutes
        gitPull = try c.decodeIfPresent(Bool.self, forKey: .gitPull) ?? d.gitPull
        ntfyURL = try c.decodeIfPresent(String.self, forKey: .ntfyURL) ?? d.ntfyURL
        launchAfterInstall = try c.decodeIfPresent(Bool.self, forKey: .launchAfterInstall) ?? d.launchAfterInstall
    }

    /// Settings that identify what gets installed where; changing one invalidates the known expiry.
    var target: [String] { [projectPath, scheme, bundleID, teamID, deviceID] }
}

enum FailureKind: String, Codable {
    case deviceUnreachable = "Apple TV unreachable"
    case authRequired = "Apple ID sign-in required"
    case signing = "Signing/provisioning error"
    case build = "Build failed"
    case install = "Install failed"
    case configuration = "Configuration incomplete"

    /// Problems only a person can fix; alert on the first occurrence.
    var needsAttention: Bool {
        switch self {
        case .authRequired, .signing, .configuration: true
        case .deviceUnreachable, .build, .install: false
        }
    }
}

struct RunRecord: Codable, Identifiable {
    var id = UUID()
    var started: Date
    var finished: Date
    var trigger: String
    var failure: FailureKind?
    var message: String
    var logFile: String
}

struct DeployState: Codable {
    var lastSuccess: Date?
    var expiry: Date?
    var consecutiveFailures = 0
    var nextRetry: Date?
    var lastFailure: FailureKind?
    var alertedFailure: FailureKind?    // suppresses repeat alerts until the next success
    var alertedUnknownExpiry: Bool?     // same, for "installed but expiry unreadable"
    var history: [RunRecord] = []
}

enum Storage {
    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ATVQ Deployer", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var logsDirectory: URL {
        let url = directory.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var derivedData: URL { directory.appendingPathComponent("DerivedData", isDirectory: true) }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
