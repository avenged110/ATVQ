// MARK: - FilmDetailPane.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Metadata for the selected film. Duration is shown while the pane has focus, or while
// the list is showing durations.

import SwiftUI

struct FilmDetailPane: View {
    let film: QueueFilm
    let poster: UIImage?
    let isFocused: Bool
    /// Durations are toggled on for the whole list (long-press on a row).
    var showsDuration = false

    /// Starts near the measured value so the first frame doesn't jump.
    @State private var headerHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 40) {
                // Exactly as tall as the block beside it, measured from the title's line top to
                // the last line's descender, so the edges line up visually rather than to a baseline.
                PosterImage(image: poster, cornerRadius: 16)
                    .frame(width: headerHeight * 2 / 3, height: headerHeight)
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 7)
                header
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            }
            // Sized for FilmTracker's synopses, which run up to ~300 characters.
            Text(film.synopsis)
                .font(.callout)
                .lineLimit(5, reservesSpace: true)
            // The credits sit on the card's bottom padding; any spare height goes between them
            // and the divider.
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                    .overlay(Color.white.opacity(0.18))
                Spacer(minLength: 16)
                credits
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(EdgeInsets(top: 26, leading: 34, bottom: 26, trailing: 34))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                OuterShadow(cornerRadius: Self.cornerRadius)
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(CellFill.pane(focused: isFocused))
            }
        }
        // The focus ring sits just outside the fill, leaving a small gap.
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius + Self.ringGap + Self.ringWidth, style: .continuous)
                .strokeBorder(.white.opacity(isFocused ? 0.85 : 0), lineWidth: Self.ringWidth)
                .padding(-(Self.ringGap + Self.ringWidth))
        }
        .scaleEffect(isFocused ? 1.015 : 1)
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }

    private static let cornerRadius: CGFloat = 36
    private static let ringGap: CGFloat = 4.5
    private static let ringWidth: CGFloat = 6

    /// Upper bound for the pane poster; posters are decoded at 2× this.
    nonisolated static let posterSize = CGSize(width: 200, height: 300)

    /// Everything beside the poster, centered on it as one block. Every row is always
    /// laid out (one line each) so switching films never moves anything.
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(film.title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .truncationMode(.tail)

            VStack(alignment: .leading, spacing: 18) {
                // First under the title, so its hidden state reads as a gap below the title
                // rather than a hole between fields.
                DurationLine(duration: film.duration, runtimeMinutes: film.runtimeMinutes)
                    .modifier(GlyphRow(symbol: "timer"))
                    .opacity(isFocused || showsDuration ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: isFocused || showsDuration)
                // One size down: this glyph's shape fills more of its box than the others'.
                glyphRow("theatermasks.fill", film.genre.isEmpty ? "Unknown genre" : film.genre, dimmed: film.genre.isEmpty,
                         symbolFont: .caption2)
                glyphRow("opticaldisc.fill", film.source.isEmpty ? "None" : film.source, dimmed: film.source.isEmpty)
                glyphRow("calendar.badge.clock", film.lastWatched.isEmpty ? "Never" : film.lastWatched, dimmed: false)
            }
        }
        .font(.caption)
    }

    private func glyphRow(_ symbol: String, _ value: String, dimmed: Bool, symbolFont: Font? = nil) -> some View {
        Text(value)
            .foregroundStyle(dimmed ? .tertiary : .primary)
            .lineLimit(1)
            .modifier(GlyphRow(symbol: symbol, symbolFont: symbolFont))
    }

    private var credits: some View {
        // Every row is always present (with a dash when empty) so the pane never reflows.
        let rows: [(label: String, names: [String], lines: Int)] = [
            ("Directed by", film.directors, 1),
            ("Starring", film.cast, 3),
            ("Written by", film.screenwriters, 1),
            ("Produced by", film.producers, 1),
        ]

        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 28, verticalSpacing: 8) {
            ForEach(rows, id: \.label) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.trailing)
                    Text(row.names.isEmpty ? "\u{2014}" : row.names.joined(separator: ", "))
                        .foregroundStyle(row.names.isEmpty ? .tertiary : .primary)
                        .lineLimit(row.lines, reservesSpace: true)
                }
            }
        }
        .font(.caption)
    }
}

/// A fixed-width SF Symbol column in front of a value, so the values align.
private struct GlyphRow: ViewModifier {
    let symbol: String
    /// Overrides the row's font for the symbol alone.
    var symbolFont: Font?

    func body(content: Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Image(systemName: symbol)
                .font(symbolFont)
                .foregroundStyle(.tertiary)
                .frame(width: 36)
            content
        }
    }
}

/// "1 hr 50 min (will end around 9:42 PM)", recomputed every minute.
private struct DurationLine: View {
    let duration: String
    let runtimeMinutes: Int?

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 10) {
                Text(duration.isEmpty ? "Unknown duration" : duration)
                if let minutes = runtimeMinutes ?? Self.parseMinutes(duration), minutes > 0 {
                    let end = context.date.addingTimeInterval(TimeInterval(minutes * 60))
                    Text("(will end around \(end.formatted(date: .omitted, time: .shortened)))")
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }

    /// Fallback for senders that omit runtimeMinutes: reads "2 hr 16 min" / "95 min".
    static func parseMinutes(_ text: String) -> Int? {
        var total = 0, number: Int?, found = false
        let lower = text.lowercased()
        var index = lower.startIndex
        while index < lower.endIndex {
            if lower[index].isNumber {
                let end = lower[index...].firstIndex { !$0.isNumber } ?? lower.endIndex
                number = Int(lower[index..<end])
                index = end
            } else if lower[index].isLetter {
                let end = lower[index...].firstIndex { !$0.isLetter } ?? lower.endIndex
                if let value = number {
                    if lower[index] == "h" { total += value * 60; found = true }
                    else if lower[index] == "m" { total += value; found = true }
                }
                number = nil
                index = end
            } else {
                index = lower.index(after: index)
            }
        }
        return found ? total : nil
    }
}

// MARK: - Badges

enum Badge {
    static let height: CGFloat = 40
    static let cornerRadius: CGFloat = 7
}

/// Solid badge with the lettering cut out of it (release year). Plate and weight follow
/// FilmTracker's ReleaseCard format badge (white 0.93, heavy). On a focused row, whose
/// background is white, the plate turns dark so the cut-out numerals still read.
struct KnockoutBadge: View {
    let text: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(text)
            .font(.caption.weight(.heavy).monospacedDigit())
            .padding(.horizontal, 12)
            .frame(height: Badge.height)
            .blendMode(.destinationOut)
            .background(RoundedRectangle(cornerRadius: Badge.cornerRadius).fill(isFocused ? Color(white: 0.12) : Color(white: 0.93)))
            .compositingGroup()
    }
}
