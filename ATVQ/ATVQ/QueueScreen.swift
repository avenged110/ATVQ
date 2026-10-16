// MARK: - QueueScreen.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The populated state: eight-slot film list on the left, metadata pane on the right.

import SwiftUI
import os

enum Log {
    static let input = Logger(subsystem: "app.ATVQ", category: "input")
}

struct QueueScreen: View {
    @Environment(QueueStore.self) private var store
    let payload: QueuePayload

    private enum FocusTarget: Hashable { case row(Int), detail }

    @FocusState private var focus: FocusTarget?
    @State private var selected = 0
    @State private var showsInstructions = false
    /// Long-press Select on any row toggles a duration line under every title (and the
    /// pane's duration row, in sync).
    @State private var durationsLaidOut = false
    @State private var durationsVisible = false
    /// Where focus was when the overlay opened, restored when it closes.
    @State private var focusBeforeOverlay: FocusTarget?

    private var films: [QueueFilm] { payload.films }
    private var selectedFilm: QueueFilm { films[min(selected, films.count - 1)] }

    var body: some View {
        ZStack {
            content
                .disabled(showsInstructions)
            // A system material fading in over the screen rather than an animated blur radius
            // on `content`: animating the radius re-blurs the whole view tree on every frame,
            // which stuttered as the overlay opened. The material is a fixed-radius GPU blur,
            // so only its opacity animates.
            if showsInstructions {
                Rectangle()
                    .fill(.thinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
                InstructionsOverlay { setInstructions(false) }
                    .transition(ScaleTransition(1.12, anchor: .center).combined(with: OpacityTransition()))
                    .zIndex(1)
            }
        }
        .background { Backdrop(image: store.backdrops[selectedFilm.id]) }
        .onPlayPauseCommand { setInstructions(!showsInstructions) }

        // Menu closes the overlay; otherwise it is left alone so it still exits to the Home screen.
        .onExitCommand(perform: exitAction)
    }

    private var exitAction: (() -> Void)? {
        guard showsInstructions else { return nil }
        return { setInstructions(false) }
    }

    /// Titles slide while the durations fade, together, in both directions.
    private func setDurations(_ on: Bool) {
        withAnimation(.smooth(duration: 0.35)) {
            durationsLaidOut = on
            durationsVisible = on
        }
    }

    private func setInstructions(_ shown: Bool) {
        guard shown != showsInstructions else { return }
        if shown { focusBeforeOverlay = focus }
        withAnimation(.smooth(duration: 0.45)) { showsInstructions = shown }
        if !shown { focus = focusBeforeOverlay ?? .row(selected) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 40) {
            HStack(alignment: .top) {
                ClockHeader(dispatchedAt: payload.dispatchedAt)
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: "playpause.circle.fill")
                    Text("for setup instructions")
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            }
            HStack(alignment: .top, spacing: 48) {
                list
                    .frame(width: 760)
                    .focusSection()
                    // Entering the list (e.g. "left" from the pane) lands directly on the selected
                    // row. Without this the engine picks the geometrically nearest row first and the
                    // redirect below makes that row blink.
                    .defaultFocus($focus, .row(selected), priority: .userInitiated)
                FilmDetailPane(film: selectedFilm,
                               poster: store.posters[selectedFilm.id],
                               isFocused: focus == .detail,
                               showsDuration: durationsVisible)
                    .frame(height: 8 * Self.rowHeight + 7 * 14)
                    // Moving focus to the pane is turned off on purpose; the focus handling for it
                    // (the `.detail` target, the pane's focused styling, the redirect back to the
                    // selected row) is kept intact. Set `detailPaneFocusable` to restore it.
                    .focusable(Self.detailPaneFocusable)
                    .focused($focus, equals: .detail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .defaultFocus($focus, .row(0))
        .onChange(of: focus) { oldValue, newValue in
            guard case .row(let index) = newValue else { return }
            // Safety net: focus arriving from the pane, or from nowhere (e.g. the overlay closing),
            // should land on the row whose details are showing. defaultFocus normally handles it.
            if oldValue == .detail || oldValue == nil, index != selected { focus = .row(selected); return }
            selected = index
        }
        // Any new queue — even one with the same timestamp — starts fresh.
        .onChange(of: payload) {
            if showsInstructions { showsInstructions = false }
            durationsLaidOut = false
            durationsVisible = false
            selected = 0
            focus = .row(0)
        }
    }

    /// Whether the remote can move focus over to the metadata pane. Off for now; see above.
    static let detailPaneFocusable = false

    // 8 × 84 + 7 × 14 = 770pt, which leaves room for the header inside the 960pt safe height.
    static let rowHeight: CGFloat = 84

    private var list: some View {
        VStack(spacing: 14) {
            ForEach(0..<QueuePayload.maxFilms, id: \.self) { index in
                if index < films.count {
                    let film = films[index]
                    Button {} label: {
                        FilmRow(film: film, poster: store.thumbnails[film.id],
                                showsDuration: durationsLaidOut)
                    }
                    .buttonStyle(QueueRowStyle(isSelected: index == selected) {
                        // Click-and-hold Select on any row toggles durations.
                        setDurations(!durationsLaidOut)
                    })
                    .focused($focus, equals: .row(index))
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 3, dash: [12, 10]))
                        .frame(height: Self.rowHeight)
                }
            }
        }
    }
}

// MARK: - Row

struct FilmRow: View {
    let film: QueueFilm
    let poster: UIImage?
    var showsDuration = false

    nonisolated static let thumbnailSize = CGSize(width: 42, height: 63)

    /// Matches the badge's trailing inset; the poster sits centered between the cell's
    /// edge and the title, with this much space on each side.
    static let edgeInset: CGFloat = 22

    var body: some View {
        HStack(spacing: Self.edgeInset) {
            PosterImage(image: poster, cornerRadius: 6)
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            // The title stays vertically centered on its own; with durations on, the pair is
            // centered instead, so the title eases up as the duration fades in beneath it.
            VStack(alignment: .leading, spacing: 2) {
                Text(film.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsDuration {
                    Text(film.duration.isEmpty ? "Unknown duration" : film.duration)
                        .font(.system(size: 20).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Fades in place while the title slides; it doesn't move itself.
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !film.year.isEmpty {
                KnockoutBadge(text: film.year)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Self.edgeInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: QueueScreen.rowHeight)
    }
}

private struct QueueRowStyle: ButtonStyle {
    let isSelected: Bool
    var onLongPress: () -> Void = {}

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, isSelected: isSelected, onLongPress: onLongPress)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let isSelected: Bool
        let onLongPress: () -> Void
        @Environment(\.isFocused) private var isFocused
        /// Pending long-press check for the current press.
        @State private var holdTask: Task<Void, Never>?

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .background {
                    ZStack {
                        if !isFocused { OuterShadow(cornerRadius: 18) }
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isFocused ? Color.white : CellFill.row(selected: isSelected))
                    }
                }
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.0 : 1.04) : 1)
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                // A long press is a press held for a full second (a deliberate gesture). tvOS Buttons consume the
                // Select press, so SwiftUI's onLongPressGesture never fires on them; the
                // button's own pressed state is the reliable signal.
                .onChange(of: configuration.isPressed) { _, pressed in
                    holdTask?.cancel()
                    holdTask = nil
                    Log.input.debug("Row press \(pressed ? "began" : "ended", privacy: .public)")
                    guard pressed else { return }
                    holdTask = Task {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        Log.input.debug("Row long press")
                        onLongPress()
                    }
                }
        }
    }
}

// MARK: - Poster

struct PosterImage: View {
    let image: UIImage?
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.white.opacity(0.1))
            .overlay {
                if let image {
                    // Filtered resampling + antialiasing: the default point-samples at large
                    // downscale ratios, which looks jagged and over-sharpened.
                    Image(uiImage: image)
                        .interpolation(.high)
                        .antialiased(true)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film").font(.title3).foregroundStyle(.white.opacity(0.4))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Cell styling

/// Translucent cell fills: dark enough to keep the backdrop glow down, light enough
/// that some of it still reads through.
enum CellFill {
    static func row(selected: Bool) -> Color { Color(white: selected ? 0.39 : 0.19).opacity(selected ? 0.46 : 0.4) }
    static func pane(focused: Bool) -> Color { Color(white: focused ? 0.345 : 0.19).opacity(focused ? 0.44 : 0.4) }
}

/// A drop shadow drawn only outside a rounded rectangle, so it doesn't darken a
/// translucent fill from underneath.
struct OuterShadow: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.black)
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            .mask {
                ZStack {
                    Rectangle().padding(-60)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Instructions overlay

/// Full-screen overlay: the screen behind blurs while the card settles from slightly
/// enlarged into place (and reverses on dismissal), like tvOS system alerts.
private struct InstructionsOverlay: View {
    let close: () -> Void
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(spacing: 60) {
            Spacer()
            InstructionsCard()
            Spacer()
            Button("Close", action: close)
                .focused($closeFocused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.25).ignoresSafeArea())
        .onAppear { closeFocused = true }
    }
}
