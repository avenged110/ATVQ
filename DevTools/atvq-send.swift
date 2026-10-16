// MARK: - atvq-send.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Lab tool: finds ATVQ over Bonjour and dispatches a test queue, exactly as FilmTracker will.
//
//   swift atvq-send.swift            # sends 3 sample films with drawn posters
//   swift atvq-send.swift 8          # sends N sample films (1–8)
//   swift atvq-send.swift queue.json # sends a QueuePayload JSON file as-is
//   add --sim when the target is the tvOS Simulator on this Mac
//   add --relay to send to the ATVQ Deployer relay instead of directly to ATVQ

import AppKit
import Network

let arg = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }

func poster(_ title: String, hue: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: 400, height: 600), flipped: false) { rect in
        NSGradient(starting: NSColor(hue: hue, saturation: 0.6, brightness: 0.7, alpha: 1),
                   ending: NSColor(hue: hue, saturation: 0.8, brightness: 0.15, alpha: 1))!.draw(in: rect, angle: -90)
        let style = NSMutableParagraphStyle(); style.alignment = .center
        title.uppercased().draw(in: NSRect(x: 30, y: 60, width: 340, height: 160), withAttributes: [
            .font: NSFont.systemFont(ofSize: 44, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: style])
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
}

func samplePayload(count: Int) -> [String: Any] {
    let titles = ["Network Test One", "Sicario", "The Third Man", "Moonrise Kingdom", "Alien", "Ran", "Zodiac", "Ikiru"]
    let films: [[String: Any]] = (0..<count).map { i in
        [
            "id": UUID().uuidString, "title": titles[i], "year": "\(1950 + i * 9)", "genre": "Drama", "rating": "PG-13",
            "duration": "\(1 + i % 2) hr \(10 + i * 5) min", "source": "Lab dispatch", "lastWatched": "",
            "synopsis": "Sent from atvq-send.swift at \(Date().formatted(date: .omitted, time: .standard)) to verify the network path.",
            "directors": ["Test Director"], "screenwriters": [], "cast": ["Actor One", "Actor Two"], "producers": [], "composers": [],
            "poster": poster(titles[i], hue: CGFloat(i) / 8).base64EncodedString(),
        ]
    }
    return ["version": 1, "dispatchedAt": ISO8601DateFormatter().string(from: Date()), "films": films]
}

let body: Data
if let arg, arg.hasSuffix(".json") {
    body = try! Data(contentsOf: URL(fileURLWithPath: arg))
} else {
    let count = max(1, min(8, Int(arg ?? "") ?? 3))
    body = try! JSONSerialization.data(withJSONObject: samplePayload(count: count))
}


// --relay: send to the ATVQ Deployer relay instead of ATVQ itself.
let serviceType = CommandLine.arguments.contains("--relay") ? "_atvqrelay._tcp" : "_atvq._tcp"
let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
print("Payload: \(body.count / 1024) KB. Browsing for \(serviceType)…")
browser.browseResultsChangedHandler = { results, _ in
    guard let result = results.first else { return }
    browser.cancel()
    print("Found \(result.endpoint). Sending…")
    // --sim: the tvOS Simulator shares this Mac's network stack, so force loopback.
    let parameters = NWParameters.tcp
    if CommandLine.arguments.contains("--sim") { parameters.requiredInterfaceType = .loopback }
    let connection = NWConnection(to: result.endpoint, using: parameters)
    connection.stateUpdateHandler = { print("Connection: \($0)") }
    connection.start(queue: .main)
    let n = UInt32(body.count)
    connection.send(content: Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: n >> $0) }) + body, completion: .contentProcessed { error in
        if let error { print("Send failed: \(error)"); exit(1) }
    })
    connection.receive(minimumIncompleteLength: 4, maximumLength: 64 * 1024) { data, _, _, error in
        guard let data, data.count > 4 else { print("No reply: \(String(describing: error))"); exit(1) }
        print("Reply: \(String(decoding: data.dropFirst(4), as: UTF8.self))")
        exit(0)
    }
}
browser.start(queue: .main)
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { print("Timed out: ATVQ not found."); exit(1) }
dispatchMain()
