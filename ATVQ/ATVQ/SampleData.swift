// MARK: - SampleData.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Placeholder queue for layout work (DEBUG only). Posters are drawn, not bundled.

#if DEBUG
import UIKit

enum SampleData {
    static func payload() -> QueuePayload {
        QueuePayload(version: QueuePayload.currentVersion, dispatchedAt: Date().addingTimeInterval(-25 * 60), films: films)
    }

    private static let films: [QueueFilm] = [
        film("Heat", "1995", "Crime", "R", "2 hr 50 min", "Blu-ray disc", "June 2021 (5 years ago)",
             "A meticulous professional thief and a relentless LAPD detective circle each other across Los Angeles as one last score comes together and both men's lives start to come apart.",
             ["Michael Mann"], ["Michael Mann"], ["Al Pacino", "Robert De Niro", "Val Kilmer", "Jon Voight", "Tom Sizemore", "Diane Venora", "Amy Brenneman", "Ashley Judd"],
             ["Art Linson", "Michael Mann"], ["Elliot Goldenthal"], hue: 0.58),
        film("The Thing", "1982", "Horror", "R", "1 hr 49 min", "4K download", "October 2024 (2 years ago)",
             "At an isolated Antarctic research station, a crew discovers that something has followed a stray dog inside, and it can perfectly imitate whatever it absorbs.",
             ["John Carpenter"], ["Bill Lancaster"], ["Kurt Russell", "Wilford Brimley", "Keith David", "Richard Masur", "T. K. Carter"],
             ["David Foster", "Lawrence Turman"], ["Ennio Morricone"], hue: 0.55),
        film("Lawrence of Arabia", "1962", "Adventure", "PG", "3 hr 48 min", "Blu-ray disc", "",
             "A British officer seconded to the Arab Revolt during the First World War becomes a legend in the desert, and is changed by it.",
             ["David Lean"], ["Robert Bolt", "Michael Wilson"], ["Peter O\u{2019}Toole", "Alec Guinness", "Anthony Quinn", "Jack Hawkins", "Omar Sharif"],
             ["Sam Spiegel"], ["Maurice Jarre"], hue: 0.09),
        film("Arrival", "2016", "Science Fiction", "PG-13", "1 hr 56 min", "1080p download", "January 2023 (3 years ago)",
             "When twelve vessels touch down around the world, a linguist is recruited to find a way to talk to their occupants before the nations of Earth run out of patience.",
             ["Denis Villeneuve"], ["Eric Heisserer"], ["Amy Adams", "Jeremy Renner", "Forest Whitaker", "Michael Stuhlbarg"],
             ["Shawn Levy", "Dan Levine", "Aaron Ryder", "David Linde"], ["J\u{F3}hann J\u{F3}hannsson"], hue: 0.5),
        film("Paddington 2", "2017", "Family", "PG", "1 hr 43 min", "4K download", "December 2025 (10 months ago)",
             "Paddington takes on odd jobs to buy the perfect birthday present for his aunt, until the gift is stolen and he is wrongly sent to prison.",
             ["Paul King"], ["Paul King", "Simon Farnaby"], ["Ben Whishaw", "Hugh Grant", "Hugh Bonneville", "Sally Hawkins", "Brendan Gleeson"],
             ["David Heyman"], ["Dario Marianelli"], hue: 0.02),
        film("Chinatown", "1974", "Mystery", "R", "2 hr 10 min", "Blu-ray disc", "May 2019 (7 years ago)",
             "A private investigator hired for a routine infidelity case in 1930s Los Angeles uncovers a scheme over the city\u{2019}s water that reaches much further than he expected.",
             ["Roman Polanski"], ["Robert Towne"], ["Jack Nicholson", "Faye Dunaway", "John Huston"],
             ["Robert Evans"], ["Jerry Goldsmith"], hue: 0.12),
    ]

    private static func film(_ title: String, _ year: String, _ genre: String, _ rating: String, _ duration: String,
                             _ source: String, _ lastWatched: String, _ synopsis: String,
                             _ directors: [String], _ writers: [String], _ cast: [String],
                             _ producers: [String], _ composers: [String], hue: CGFloat) -> QueueFilm {
        QueueFilm(id: UUID(), title: title, year: year, genre: genre, rating: rating, duration: duration,
                  source: source, lastWatched: lastWatched, synopsis: synopsis, directors: directors,
                  screenwriters: writers, cast: cast, producers: producers, composers: composers,
                  poster: poster(title: title, hue: hue))
    }

    private static func poster(title: String, hue: CGFloat) -> Data? {
        let size = CGSize(width: 400, height: 600)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            // Banded vertical gradient (CGGradient's initializer is flagged as unsafe).
            let bands = 60
            for band in 0..<bands {
                let t = CGFloat(band) / CGFloat(bands - 1)
                UIColor(hue: hue, saturation: 0.7 + 0.1 * t, brightness: 0.55 - 0.4 * t, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: size.height * CGFloat(band) / CGFloat(bands), width: size.width, height: size.height / CGFloat(bands) + 1))
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .heavy),
                .foregroundColor: UIColor.white,
                .paragraphStyle: style,
            ]
            title.uppercased().draw(in: CGRect(x: 30, y: 380, width: 340, height: 180), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.85)
    }
}
#endif
