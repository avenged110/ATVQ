// MARK: - ContentView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Root view: switches between the empty (instructions) state and the queue.

import SwiftUI

struct ContentView: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        ZStack {
            if !store.isReady {
                // Identical to the launch screen, held until the saved queue is decoded, then
                // crossfaded into whichever screen applies.
                Backdrop(image: nil)
                    .transition(.opacity)
            } else if let payload = store.payload {
                QueueScreen(payload: payload)
                    .transition(.opacity)
            } else {
                EmptyScreen()
                    .transition(.opacity)
                    #if DEBUG
                    // Play/Pause on the empty screen loads placeholder data (not saved).
                    .onPlayPauseCommand { store.apply(SampleData.payload(), persist: false) }
                    #endif
            }
        }
    }
}

// MARK: - Empty state

private struct EmptyScreen: View {
    var body: some View {
        ZStack {
            VStack(alignment: .leading) {
                ClockHeader(dispatchedAt: nil)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            InstructionsCard()
        }
        .background { AbstractBackdrop() }
    }
}

// MARK: - Shared pieces

/// The instructions screen's own backdrop, used only before anything has been dispatched:
/// soft, unequal blooms of color on the usual dark gradient, so the card has something to
/// stand out from. Radial gradients rather than blurred shapes, so it costs nothing to draw.
struct AbstractBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(red: 0.06, green: 0.07, blue: 0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            bloom(Color(red: 0.16, green: 0.34, blue: 0.80), at: UnitPoint(x: 0.18, y: 0.22), radius: 900, strength: 0.55)
            bloom(Color(red: 0.62, green: 0.16, blue: 0.58), at: UnitPoint(x: 0.82, y: 0.30), radius: 800, strength: 0.45)
            bloom(Color(red: 0.08, green: 0.55, blue: 0.62), at: UnitPoint(x: 0.62, y: 0.92), radius: 900, strength: 0.45)
            bloom(Color(red: 0.85, green: 0.38, blue: 0.20), at: UnitPoint(x: 0.08, y: 0.95), radius: 600, strength: 0.30)
            Color.black.opacity(0.2)
        }
        .ignoresSafeArea()
    }

    private func bloom(_ color: Color, at center: UnitPoint, radius: CGFloat, strength: Double) -> some View {
        RadialGradient(colors: [color.opacity(strength), color.opacity(strength * 0.35), color.opacity(0)],
                       center: center, startRadius: 0, endRadius: radius)
    }
}

/// Approximates the tvOS home backdrop: a heavily blurred image over a dark gradient.
///
/// Changing images crossfade explicitly: the new image fades in, opaque, over the old one,
/// which is removed only once it's fully covered. The blur and the 0.55 opacity apply to the
/// stack as a whole, so the old image never shows through, dims, or drops out mid-fade.
struct Backdrop: View {
    let image: UIImage?

    private struct Layer: Identifiable {
        let id = UUID()
        let image: UIImage?
        var opacity: Double
    }

    @State private var layers: [Layer] = []
    private static let fade = Animation.easeInOut(duration: 0.6)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(red: 0.06, green: 0.07, blue: 0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            ZStack {
                ForEach(layers) { layer in
                    if let image = layer.image {
                        // Each layer is blurred on its own and overscans the screen: a blur fades
                        // an image's edges to transparent over ~3× the radius, so the fade has to
                        // fall offscreen. Fading the layers' opacity, rather than blurring the
                        // group, keeps the result a plain blend of the two images.
                        Image(uiImage: image)
                            .interpolation(.medium)
                            .resizable()
                            .scaledToFill()
                            .padding(-200)
                            .blur(radius: 50)
                            .opacity(layer.opacity)
                    }
                }
            }
            .compositingGroup()
            .opacity(0.55)
            Color.black.opacity(0.2)
        }
        .ignoresSafeArea()
        .onAppear { if layers.isEmpty { layers = [Layer(image: image, opacity: 1)] } }
        .onChange(of: image.map(ObjectIdentifier.init)) { show(image) }
    }

    private func show(_ image: UIImage?) {
        // A nil image fades in as an empty layer, which fades the old one out over the gradient.
        let incoming = Layer(image: image, opacity: 0)
        layers.append(incoming)
        // Next turn of the run loop, so the layer is on screen at 0 before it animates.
        Task { @MainActor in
            withAnimation(Self.fade) {
                if let index = layers.firstIndex(where: { $0.id == incoming.id }) { layers[index].opacity = 1 }
                // An empty layer covers nothing, so the ones under it fade out instead.
                if image == nil { for index in layers.indices where layers[index].id != incoming.id { layers[index].opacity = 0 } }
            } completion: {
                // Everything under the newest finished layer is now hidden.
                guard let index = layers.firstIndex(where: { $0.id == incoming.id }) else { return }
                layers.removeFirst(index)
            }
        }
    }
}

struct ClockHeader: View {
    let dispatchedAt: Date?

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 6) {
                // "11:56 PM on Wednesday, October 14, 2026"
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(context.date.formatted(.dateTime.hour().minute()))
                    Text(" on ").foregroundStyle(.tertiary)
                    Text(context.date.formatted(.dateTime.weekday(.wide)))
                    Text(", " + context.date.formatted(.dateTime.month(.wide).day().year()) + ".")
                        .foregroundStyle(.tertiary)
                }
                .font(.title3.weight(.semibold))
                if let dispatchedAt {
                    Text("Dispatched from Film Tracker \(Self.relative(dispatchedAt, now: context.date)).")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear ? date.formatted(.dateTime.month(.wide).day()) : date.formatted(.dateTime.month(.wide).day().year())
        return "on \(day) at \(time)"
    }
}

struct InstructionsCard: View {
    private let steps = [
        "Ensure your Mac and this Apple TV are on the same network.",
        "Launch FilmTracker 1.0.1 or later and make sure \u{201C}ATVQ integration\u{201D} is enabled in its settings.",
        "Add two or more films to your \u{201C}Up Next\u{201D} Queue in FilmTracker, up to a maximum of eight.",
        "Select the \u{201C}Dispatch to ATVQ\u{201D} button and your films should appear here.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 44) {
            Label("Send Your Queue to Apple TV", systemImage: "appletv.fill")
                .font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 32) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 28) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(.white.opacity(0.14)))
                            .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] }
                        Text(step)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(64)
        .frame(width: 1100, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 40, style: .continuous).fill(.regularMaterial))
    }
}
