import Foundation

/// Most-recently-used ordering for the transcription-language picker.
///
/// The picker's full list is alphabetical (`LanguageChoice.presentationOrder`),
/// which buries the one or two languages a given user actually dictates in. This
/// helper maintains a small MRU list (newest first, capped at `maxCount`) so the
/// picker can pin a "Recent" section above the full A–Z list.
///
/// Persistence is a single comma-joined `@AppStorage` string of raw values
/// (`jot.recentLanguages`) — no SwiftData, no per-recording scan. All logic here
/// is **pure** (raw-string in, value out) so it's trivially testable and the
/// view only holds the `@AppStorage` binding.
enum RecentLanguages {
    static let key = "jot.recentLanguages"
    static let maxCount = 5

    /// The ordered list to render in the "Recent" section.
    ///
    /// - The active `current` selection is always first (it's the most recent
    ///   use by definition), followed by prior picks from `raw`.
    /// - When `raw` is empty (first run, before any pick) the list is seeded
    ///   from the system locale so even a brand-new user gets a one-tap pin.
    /// - Filtered to currently-eligible languages (`presentationOrder` already
    ///   drops retired / hardware-ineligible languages), de-duplicated, and
    ///   capped at `maxCount`.
    static func display(
        fromRaw raw: String,
        current: LanguageChoice,
        locale: Locale = .current
    ) -> [LanguageChoice] {
        let eligible = Set(LanguageChoice.presentationOrder)
        var stored = parse(raw)
        if stored.isEmpty {
            stored = [LanguageChoice.fromSystemLocale(locale)]
        }
        var seen = Set<LanguageChoice>()
        var result: [LanguageChoice] = []
        for lang in [current] + stored where eligible.contains(lang) && seen.insert(lang).inserted {
            result.append(lang)
        }
        return Array(result.prefix(maxCount))
    }

    /// The new persisted raw string after the user picks `picked`: moved to the
    /// front, de-duplicated, capped at `maxCount`.
    static func recordedRaw(fromRaw raw: String, picked: LanguageChoice) -> String {
        var stored = parse(raw)
        stored.removeAll { $0 == picked }
        stored.insert(picked, at: 0)
        return stored.prefix(maxCount).map(\.rawValue).joined(separator: ",")
    }

    private static func parse(_ raw: String) -> [LanguageChoice] {
        raw.split(separator: ",").compactMap { LanguageChoice(rawValue: String($0)) }
    }
}
