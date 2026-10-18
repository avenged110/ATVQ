// MARK: - Tools.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Thin wrappers around devicectl, security and ntfy, plus failure classification.

import Foundation
import Security

struct TVDevice: Identifiable, Hashable {
    var id: String
    var name: String
    var detail: String
}

enum Tools {
    static let xcrun = "/usr/bin/xcrun"

    /// tvOS devices known to devicectl (paired via Xcode).
    static func listDevices(log: @escaping @Sendable (String) -> Void) async -> [TVDevice] {
        let json = FileManager.default.temporaryDirectory.appendingPathComponent("devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: json) }
        _ = await ProcessRunner.run(xcrun, ["devicectl", "list", "devices", "--json-output", json.path], timeout: 60, onLine: log)
        guard let data = try? Data(contentsOf: json),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { device in
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            guard (hardware["platform"] as? String)?.lowercased().contains("tvos") == true,
                  let id = device["identifier"] as? String else { return nil }
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            let state = [connection["pairingState"], connection["tunnelState"]].compactMap { $0 as? String }.joined(separator: ", ")
            return TVDevice(id: id, name: properties["name"] as? String ?? "Apple TV",
                            detail: [hardware["marketingName"] as? String, state].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// Team IDs of the "Apple Development" signing identities in the keychain (certificate and
    /// private key both present). Xcode creates one per team the first time it signs for it;
    /// a free Personal Team has exactly one. The team ID is the certificate's subject OU.
    static func developmentTeamIDs() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var items: CFTypeRef?
        guard unsafe SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let identities = items as? [SecIdentity] else { return [] }
        var teams: [String] = []
        for identity in identities {
            var certificate: SecCertificate?
            guard unsafe SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  let summary = SecCertificateCopySubjectSummary(certificate) as String?,
                  summary.hasPrefix("Apple Development"),
                  let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any],
                  let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
                  let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]] else { continue }
            for field in fields where field[kSecPropertyKeyLabel as String] as? String == kSecOIDOrganizationalUnitName as String {
                if let team = field[kSecPropertyKeyValue as String] as? String, !teams.contains(team) { teams.append(team) }
            }
        }
        return teams
    }

    /// Decodes a .mobileprovision (CMS-signed plist).
    static func decodeProfile(_ url: URL) async -> ProvisioningProfile? {
        let result = await ProcessRunner.run("/usr/bin/security", ["cms", "-D", "-i", url.path], timeout: 30) { _ in }
        guard result.succeeded, let start = result.output.range(of: "<?xml") else { return nil }
        return try? PropertyListDecoder().decode(ProvisioningProfile.self, from: Data(result.output[start.lowerBound...].utf8))
    }

    /// The fields of a decoded provisioning profile that the deployer reads.
    nonisolated struct ProvisioningProfile: Decodable, Sendable {
        struct Entitlements: Decodable, Sendable {
            var applicationIdentifier: String?
            enum CodingKeys: String, CodingKey { case applicationIdentifier = "application-identifier" }
        }
        var expirationDate: Date?
        var entitlements: Entitlements?
        enum CodingKeys: String, CodingKey { case expirationDate = "ExpirationDate", entitlements = "Entitlements" }
    }

    /// Reads ExpirationDate from the app's embedded provisioning profile.
    static func profileExpiry(appURL: URL) async -> Date? {
        await decodeProfile(appURL.appendingPathComponent("embedded.mobileprovision"))?.expirationDate
    }

    /// Where Xcode caches provisioning profiles (Xcode 16+, then the older location).
    static var profileDirectories: [URL] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return [library.appendingPathComponent("Developer/Xcode/UserData/Provisioning Profiles"),
                library.appendingPathComponent("MobileDevice/Provisioning Profiles")]
    }

    /// Cached profiles for `bundleID` that expire before `deadline`. Xcode keeps reusing a
    /// cached profile until it has actually expired, so these must be moved aside for
    /// -allowProvisioningUpdates to fetch a fresh 7-day one.
    static func expiringProfiles(for bundleID: String, before deadline: Date) async -> [URL] {
        var matches: [URL] = []
        for directory in profileDirectories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where ["mobileprovision", "provisionprofile"].contains(file.pathExtension) {
                guard let profile = await decodeProfile(file),
                      let appID = profile.entitlements?.applicationIdentifier,
                      appID.hasSuffix(".\(bundleID)"),
                      let expiry = profile.expirationDate, expiry < deadline else { continue }
                matches.append(file)
            }
        }
        return matches
    }

    /// Classifies a failure. For builds only the error lines are examined: a full xcodebuild
    /// log contains words like "unavailable" or "design in" that would otherwise match.
    static func classify(_ output: String, stage: FailureKind) -> FailureKind {
        var text = output.lowercased()
        if stage == .build {
            text = text.split(separator: "\n")
                .filter { $0.contains("error") || $0.contains("** build failed") }
                .joined(separator: "\n")
        }
        let auth = ["no accounts", "session has expired", "sign in to", "please sign in", "not signed in",
                    "re-enter your password", "unauthorized", "authentication failed"]
        let signing = ["provisioning profile", "no profiles for", "requires a development team", "code signing", "signing certificate",
                       "maximum number of", "app id", "device not registered", "isn't registered", "not renewed"]
        let unreachable = ["not found", "unable to locate", "not connected", "unavailable", "timed out", "could not connect",
                           "no such device", "is not paired", "offline", "tunnel"]
        if auth.contains(where: text.contains) { return .authRequired }
        if signing.contains(where: text.contains) { return .signing }
        if stage != .build, unreachable.contains(where: text.contains) { return .deviceUnreachable }
        return stage
    }

    /// Push alert via ntfy (local notifications are useless on a headless Mac).
    @discardableResult
    static func alert(_ urlString: String, title: String, message: String, urgent: Bool) async -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(message.utf8)
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue(urgent ? "high" : "default", forHTTPHeaderField: "Priority")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    }
}
