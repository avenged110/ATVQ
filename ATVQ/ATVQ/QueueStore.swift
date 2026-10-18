// MARK: - QueueStore.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Holds the most recently dispatched queue and persists it across launches.
// Posters are decoded and downscaled off the main thread before the queue is published,
// so focus movement never pays for JPEG decoding.

import SwiftUI

@Observable
final class QueueStore {
    private(set) var payload: QueuePayload?
    private(set) var posters: [UUID: UIImage] = [:]
    /// Row-sized copies resampled with high-quality filtering (see `render`).
    private(set) var thumbnails: [UUID: UIImage] = [:]
    /// Tiny copies for the blurred backdrop: blurring ~48px and scaling up looks the same as
    /// blurring a full poster and costs a fraction of the GPU time.
    private(set) var backdrops: [UUID: UIImage] = [:]

    var films: [QueueFilm] { payload?.films ?? [] }
    /// False until the saved queue (if any) has been loaded and decoded, so launch shows the
    /// bare backdrop — identical to the launch screen — instead of briefly flashing the
    /// empty-state instructions before the queue appears.
    private(set) var isReady = false

    /// What the byline says about fetching (see ClockHeader).
    enum RefreshState: Equatable {
        case idle
        /// Asking the relay for a newer queue, on launch and on returning to the foreground.
        case checking
        /// A newer queue just arrived and is on screen; shown briefly.
        case updated
        /// The relay answered and had nothing newer; shown briefly.
        case upToDate
        /// The relay couldn't be reached within RelayClient's grace period (polling goes on).
        case unreachable
    }
    private(set) var refresh: RefreshState = .idle
    /// A queue that just arrived is being decoded.
    var isDecoding: Bool { decoding > 0 }
    private var decoding = 0
    private var refreshGeneration = 0

    func refreshStarted() { setRefresh(.checking) }

    /// The relay answered (or didn't, in time). Ignored once a newer queue has already arrived,
    /// since by then there's nothing left to check for.
    func refreshFinished(reachedRelay: Bool) {
        guard refresh == .checking else { return }
        setRefresh(reachedRelay ? .upToDate : .unreachable)
    }

    private func setRefresh(_ state: RefreshState) {
        refreshGeneration += 1
        refresh = state
        // The outcomes are a confirmation, not a status: they fade after a few seconds.
        guard state == .updated || state == .upToDate else { return }
        let generation = refreshGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(state == .updated ? 6 : 4))
            if refreshGeneration == generation { refresh = .idle }
        }
    }

    /// Bumped per apply so a slow decode can't overwrite a newer queue.
    private var generation = 0
    /// Newest dispatch accepted so far. The same queue can arrive twice (directly from
    /// FilmTracker and again via the relay), and a relay may hold an older one. RelayClient
    /// sends it with each poll so the relay only answers with something newer.
    @ObservationIgnored private(set) var newestDispatch: Date?
    /// Film IDs of that dispatch: an equal timestamp with different films is a genuinely new
    /// dispatch (second-precision senders), while equal films is a duplicate.
    @ObservationIgnored private(set) var newestFilmIDs: [UUID] = []
    /// What RelayClient reports holding when it polls.
    var newestHeld: (date: Date, filmIDs: [UUID])? { newestDispatch.map { ($0, newestFilmIDs) } }

    /// A held dispatch dated further ahead than this is treated as a clock error, not as the
    /// newest: one bad timestamp from the sender's Mac would otherwise block every later queue
    /// (and stay saved) until real time caught up with it.
    nonisolated static let futureSlack: TimeInterval = 10 * 60

    /// Serial, so a quick second dispatch can never be overwritten on disk by the first.
    private nonisolated static let diskQueue = DispatchQueue(label: "ATVQ.QueueStore.disk", qos: .utility)

    private nonisolated static var fileURL: URL {
        // tvOS only guarantees Caches; the system may purge it, which just shows the empty state.
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("queue.json")
    }

    init() {
        Task {
            let saved = await withCheckedContinuation { continuation in
                Self.diskQueue.async {
                    let data = try? Data(contentsOf: Self.fileURL)
                    continuation.resume(returning: data.flatMap { try? JSONDecoder.atvq.decode(QueuePayload.self, from: $0) })
                }
            }
            // apply() ignores it if something newer arrived while loading.
            if let saved { await applyNow(saved) }
            withAnimation(.easeInOut(duration: 0.35)) { isReady = true }
        }
    }

    func apply(_ newPayload: QueuePayload, persist: Bool = true) {
        // Counted from now, not from when the task starts, so the byline never blinks idle
        // between the relay's answer and the decode.
        decoding += 1
        Task {
            await applyNow(newPayload, persist: persist)
            decoding -= 1
        }
    }

    /// Like apply(), but returns once the queue is decoded and published.
    func applyNow(_ newPayload: QueuePayload, persist: Bool = false) async {
        let filmIDs = newPayload.films.map(\.id)
        if let newestDispatch {
            if newPayload.dispatchedAt == newestDispatch, filmIDs == newestFilmIDs { return }
            let implausible = newestDispatch > Date().addingTimeInterval(Self.futureSlack)
            if newPayload.dispatchedAt < newestDispatch, !implausible { return }
        }
        newestDispatch = newPayload.dispatchedAt
        newestFilmIDs = filmIDs
        generation += 1
        let current = generation

        var trimmed = newPayload
        trimmed.films = Array(newPayload.films.prefix(QueuePayload.maxFilms))
        let films = trimmed.films   // with poster bytes, for decoding

        // Saved in arrival order (serial queue), before the slow decode.
        if persist {
            Self.diskQueue.async {
                try? JSONEncoder.atvq.encode(newPayload).write(to: Self.fileURL, options: .atomic)
            }
        }

        let images = await Task.detached(priority: .userInitiated) { Self.decode(films) }.value
        guard current == generation else { return }
        // The decoded images are all the UI needs; don't keep megabytes of JPEG around.
        var shown = trimmed
        for index in shown.films.indices { shown.films[index].poster = nil }
        posters = images.posters
        thumbnails = images.thumbnails
        backdrops = images.backdrops
        payload = shown.films.isEmpty ? nil : shown
        // The saved queue loading at launch isn't news; anything after that is.
        if isReady { setRefresh(.updated) }
    }

    private nonisolated static func decode(_ films: [QueueFilm])
        -> (posters: [UUID: UIImage], thumbnails: [UUID: UIImage], backdrops: [UUID: UIImage]) {
        var posters: [UUID: UIImage] = [:], thumbnails: [UUID: UIImage] = [:], backdrops: [UUID: UIImage] = [:]
        // 2× the on-screen sizes covers 4K output.
        let posterPixels = CGSize(width: FilmDetailPane.posterSize.width * 2, height: FilmDetailPane.posterSize.height * 2)
        let thumbPixels = CGSize(width: FilmRow.thumbnailSize.width * 2, height: FilmRow.thumbnailSize.height * 2)
        for film in films {
            guard let data = film.poster, let image = UIImage(data: data) else { continue }
            posters[film.id] = render(image, fitting: posterPixels)
            thumbnails[film.id] = render(image, fitting: thumbPixels)
            backdrops[film.id] = render(image, fitting: CGSize(width: 48, height: 72))
        }
        return (posters, thumbnails, backdrops)
    }

    /// Downscales with Core Graphics' high-quality (multi-tap, filtered) resampling into a
    /// decoded bitmap. Large reductions done by the GPU at draw time, or by fast thumbnailing,
    /// alias fine detail into a jagged, over-sharpened look.
    private nonisolated static func render(_ image: UIImage, fitting bounds: CGSize) -> UIImage {
        let size = fit(image.size, in: bounds)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private nonisolated static func fit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(1, min(bounds.width / size.width, bounds.height / size.height))
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
