// MARK: - QueuePayload.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The wire format FilmTracker dispatches to ATVQ. Text fields arrive display-ready,
// so ATVQ never needs to know how FilmTracker stores or formats anything.
//
// Wire protocol (TCP, Bonjour type `_atvq._tcp`):
//   request:  4-byte big-endian length, then that many bytes of JSON (QueuePayload)
//   response: 4-byte big-endian length, then JSON (QueueReply)
// Dates are ISO 8601 (fractional seconds optional); poster bytes are base64.
// Senders should include fractional seconds in dispatchedAt: it's how "newest" is decided.

import Foundation
import Network

nonisolated struct QueuePayload: Codable, Equatable {
    static let currentVersion = 1
    static let maxFilms = 8

    var version: Int
    var dispatchedAt: Date
    var films: [QueueFilm]
}

nonisolated struct QueueFilm: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var year: String
    var genre: String
    var rating: String          // MPAA, e.g. "PG-13"
    var duration: String        // e.g. "2 hr 16 min"
    var runtimeMinutes: Int?    // drives "will end around …"; optional so older senders still decode
    var source: String          // e.g. "4K download"
    var lastWatched: String     // e.g. "March 2023 (3 years ago)"; empty if never
    var synopsis: String
    var directors: [String]
    var screenwriters: [String]
    var cast: [String]
    var producers: [String]
    var composers: [String]
    var poster: Data?           // JPEG or PNG
}

// In an extension so the memberwise initializer is kept.
nonisolated extension QueueFilm {
    /// Tolerant decoding: only `title` is required. A missing or null field becomes empty
    /// rather than rejecting the whole dispatch, so a sender that omits a field ATVQ no
    /// longer shows (or adds one later) still gets through.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "" }
        func list(_ key: CodingKeys) -> [String] { ((try? c.decodeIfPresent([String].self, forKey: key)) ?? nil) ?? [] }
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        year = text(.year); genre = text(.genre); rating = text(.rating); duration = text(.duration)
        runtimeMinutes = (try? c.decodeIfPresent(Int.self, forKey: .runtimeMinutes)) ?? nil
        source = text(.source); lastWatched = text(.lastWatched); synopsis = text(.synopsis)
        directors = list(.directors); screenwriters = list(.screenwriters); cast = list(.cast)
        producers = list(.producers); composers = list(.composers)
        poster = (try? c.decodeIfPresent(Data.self, forKey: .poster)) ?? nil
    }
}

nonisolated struct QueueReply: Codable {
    var ok: Bool
    var error: String?
}

nonisolated extension JSONEncoder {
    /// Fractional seconds, so two dispatches in the same second still order correctly.
    static var atvq: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }
}

nonisolated extension JSONDecoder {
    /// Accepts ISO 8601 with or without fractional seconds (`.iso8601` rejects the latter,
    /// which many encoders emit).
    static var atvq: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unrecognized date \(text)"))
        }
        return decoder
    }
}

/// 4-byte big-endian length prefix, then the body.
nonisolated enum Framing {
    static let maxBytes = 64 * 1024 * 1024

    static func frame(_ body: Data) -> Data {
        let length = UInt32(body.count)
        return Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) }) + body
    }

    /// Reads one frame; completes with nil on error, EOF or an invalid length.
    static func receive(on connection: NWConnection, completion: @escaping @MainActor (Data?) -> Void) {
        receiveExactly(4, on: connection) { header in
            guard let header else { completion(nil); return }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= maxBytes else { completion(nil); return }
            receiveExactly(length, on: connection, completion: completion)
        }
    }

    /// Network.framework buffers until exactly `count` bytes are available (or the
    /// connection ends), so no manual accumulation is needed.
    private static func receiveExactly(_ count: Int, on connection: NWConnection,
                                       completion: @escaping @MainActor (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
            Task { @MainActor in completion(data?.count == count ? data : nil) }
        }
    }
}
