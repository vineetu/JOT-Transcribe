import Foundation

/// Deterministic, model-free date-range extraction for Ask Jot transcript
/// queries. Ported from jot-mobile (`AskController` date subsystem). The whole
/// point is to keep relative-date math OUT of the LLM (Apple FM and most models
/// are non-deterministic / wrong on "last week" relative to today): the parser
/// owns it and the result is applied as a hard `createdAt` window filter on the
/// candidate set, never by editing the query string.
///
/// Pure Foundation (`Calendar`, `DateInterval`, `NSRegularExpression`); uses
/// `Calendar.current`, so week-start day + formatting follow the user's locale.
enum AskDateScope {
    /// A resolved time window plus a human-readable label for messaging.
    struct DateScope: Equatable {
        let interval: DateInterval
        let label: String
    }

    private static let wordNumbers: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "couple": 2, "three": 3, "few": 3,
        "four": 4, "several": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10,
    ]

    private static let monthNumbers: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    private static let weekdayNumbers: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    /// Deterministic, model-free extraction of a date range from the question.
    /// Returns nil when there's no recognizable time reference (caller then
    /// falls back to semantic retrieval). First match wins.
    static func parseDateScope(from question: String, now: Date) -> DateScope? {
        let calendar = Calendar.current
        let lower = question.lowercased()
        let startOfToday = calendar.startOfDay(for: now)

        func matches(_ pattern: String) -> Bool {
            lower.range(of: pattern, options: .regularExpression) != nil
        }

        if matches(#"\btoday\b"#) {
            return DateScope(interval: DateInterval(start: startOfToday, end: now), label: "today")
        }
        if matches(#"\byesterday\b"#),
           let startYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) {
            return DateScope(
                interval: DateInterval(start: startYesterday, end: startOfToday),
                label: "yesterday"
            )
        }
        if let scope = matchWeekday(lower, startOfToday: startOfToday, calendar: calendar) {
            return scope
        }
        if let scope = matchAgo(lower, now: now, startOfToday: startOfToday, calendar: calendar) {
            return scope
        }
        if let scope = matchRelativeRange(lower, now: now, startOfToday: startOfToday, calendar: calendar) {
            return scope
        }
        // True calendar week, `this` ≠ `last`.
        if let m = lower.range(of: #"\b(this|last|past|previous)\s+week\b"#, options: .regularExpression),
           let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) {
            if lower[m].hasPrefix("this") {
                return DateScope(interval: DateInterval(start: weekInterval.start, end: now), label: "this week")
            } else if let prevStart = calendar.date(byAdding: .day, value: -7, to: weekInterval.start) {
                return DateScope(interval: DateInterval(start: prevStart, end: weekInterval.start), label: "last week")
            }
        }
        // True calendar month, `this` ≠ `last`.
        if let m = lower.range(of: #"\b(this|last|past|previous)\s+month\b"#, options: .regularExpression),
           let monthInterval = calendar.dateInterval(of: .month, for: now) {
            if lower[m].hasPrefix("this") {
                return DateScope(interval: DateInterval(start: monthInterval.start, end: now), label: "this month")
            } else if let prevAnchor = calendar.date(byAdding: .month, value: -1, to: monthInterval.start),
                      let prevInterval = calendar.dateInterval(of: .month, for: prevAnchor) {
                return DateScope(interval: prevInterval, label: "last month")
            }
        }
        if let scope = matchYear(lower, now: now, calendar: calendar) {
            return scope
        }
        if let scope = matchDateRange(lower, now: now, calendar: calendar) {
            return scope
        }
        if let scope = matchBareMonth(lower, now: now, calendar: calendar) {
            return scope
        }
        if let scope = matchSpecificDate(lower, now: now, calendar: calendar) {
            return scope
        }
        return nil
    }

    /// "last/this/past <weekday>" → the most recent occurrence of that weekday
    /// strictly before today.
    private static func matchWeekday(_ lower: String, startOfToday: Date, calendar: Calendar) -> DateScope? {
        let alt = weekdayNumbers.keys.joined(separator: "|")
        guard let m = lower.range(of: #"\b(?:last|this|past|previous)\s+(\#(alt))\b"#, options: .regularExpression) else {
            return nil
        }
        let frag = String(lower[m])
        guard let target = weekdayNumbers.first(where: { frag.contains($0.key) })?.value else { return nil }
        var day = startOfToday
        repeat {
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
            day = prev
        } while calendar.component(.weekday, from: day) != target
        guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
        return DateScope(interval: DateInterval(start: day, end: end), label: f.string(from: day))
    }

    /// "N days/weeks/months ago" (N as digit or word).
    private static func matchAgo(_ lower: String, now: Date, startOfToday: Date, calendar: Calendar) -> DateScope? {
        let numAlt = wordNumbers.keys.joined(separator: "|")
        let pattern = #"\b(\d+|\#(numAlt))\s+(day|days|week|weeks|month|months)\s+ago\b"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = lower as NSString
        guard let m = rx.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let numStr = ns.substring(with: m.range(at: 1)); let unit = ns.substring(with: m.range(at: 2))
        let n = Int(numStr) ?? wordNumbers[numStr] ?? 1; guard n > 0 else { return nil }
        if unit.hasPrefix("day") {
            guard let day = calendar.date(byAdding: .day, value: -n, to: startOfToday),
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return DateScope(interval: DateInterval(start: day, end: end), label: "\(n) day\(n == 1 ? "" : "s") ago")
        } else if unit.hasPrefix("week") {
            guard let anchor = calendar.date(byAdding: .day, value: -7 * n, to: startOfToday),
                  let wi = calendar.dateInterval(of: .weekOfYear, for: anchor) else { return nil }
            return DateScope(interval: wi, label: "\(n) week\(n == 1 ? "" : "s") ago")
        } else {
            guard let anchor = calendar.date(byAdding: .month, value: -n, to: now),
                  let mi = calendar.dateInterval(of: .month, for: anchor) else { return nil }
            return DateScope(interval: mi, label: "\(n) month\(n == 1 ? "" : "s") ago")
        }
    }

    /// "last year" / "this year" / an explicit "20xx" → that calendar year.
    private static func matchYear(_ lower: String, now: Date, calendar: Calendar) -> DateScope? {
        func yearScope(_ y: Int, openEnded: Bool) -> DateScope? {
            guard let start = calendar.date(from: DateComponents(year: y, month: 1, day: 1)),
                  let end = openEnded ? now : calendar.date(from: DateComponents(year: y + 1, month: 1, day: 1)) else { return nil }
            return DateScope(interval: DateInterval(start: start, end: end), label: "\(y)")
        }
        let thisYear = calendar.component(.year, from: now)
        if lower.range(of: #"\blast year\b"#, options: .regularExpression) != nil { return yearScope(thisYear - 1, openEnded: false) }
        if lower.range(of: #"\bthis year\b"#, options: .regularExpression) != nil { return yearScope(thisYear, openEnded: true) }
        // A bare 4-digit year ("my 2025 goals") is NOT a time scope — only when
        // it follows a date preposition.
        if let rx = try? NSRegularExpression(pattern: #"\b(?:in|during|from|since|back in)\s+(20\d{2})\b"#) {
            let ns = lower as NSString
            if let m = rx.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)),
               let y = Int(ns.substring(with: m.range(at: 1))) {
                return yearScope(y, openEnded: y == thisYear)
            }
        }
        return nil
    }

    /// A bare month name behind a date preposition or "month of" — "in June",
    /// "during May", "the month of March", "for April" — resolves to that whole
    /// calendar month (this year, or last year if the month is still in the
    /// future). The preposition / "month of" lead-in is required so common-word
    /// months ("may", "march") aren't matched as verbs, and a trailing day
    /// number is excluded so "June 5" stays a specific date (handled earlier).
    private static func matchBareMonth(_ lower: String, now: Date, calendar: Calendar) -> DateScope? {
        let monthAlt = monthNumbers.keys.joined(separator: "|")
        let pattern = #"\b(?:in|during|for|throughout|within|(?:the\s+)?month\s+of)\s+(\#(monthAlt))\b(?!\s+\d)"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = lower as NSString
        guard let m = rx.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)),
              let month = monthNumbers[ns.substring(with: m.range(at: 1))] else { return nil }
        let year = calendar.component(.year, from: now)
        guard var anchor = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return nil }
        // A month that hasn't started yet this year means last year's instance.
        if anchor > now, let prev = calendar.date(byAdding: .year, value: -1, to: anchor) {
            anchor = prev
        }
        guard let monthInterval = calendar.dateInterval(of: .month, for: anchor) else { return nil }
        // Cap the current month at "now" (open-ended); past months stay whole.
        let end = min(monthInterval.end, max(now, monthInterval.start))
        let f = DateFormatter(); f.dateFormat = "MMMM"
        return DateScope(interval: DateInterval(start: monthInterval.start, end: end), label: f.string(from: anchor))
    }

    /// "between May 1 and May 10" / "from May 1 to May 10" / "May 1 to May 10".
    private static func matchDateRange(_ lower: String, now: Date, calendar: Calendar) -> DateScope? {
        let mdAlt = monthNumbers.keys.joined(separator: "|")
        let md = #"(?:(?:\#(mdAlt))\s+\d{1,2}(?:st|nd|rd|th)?|\d{1,2}(?:st|nd|rd|th)?\s+(?:\#(mdAlt)))"#
        let patterns = [
            #"\bbetween\s+(\#(md))\s+and\s+(\#(md))\b"#,
            #"\b(\#(md))\s+(?:to|through|until|[-–—])\s+(\#(md))\b"#,
        ]
        for pattern in patterns {
            guard let m = lower.range(of: pattern, options: .regularExpression) else { continue }
            let dates = allMonthDays(String(lower[m]), now: now, calendar: calendar)
            guard let first = dates.min(), let last = dates.max(), first != last,
                  let end = calendar.date(byAdding: .day, value: 1, to: last) else { continue }
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return DateScope(interval: DateInterval(start: first, end: end), label: "\(f.string(from: first))–\(f.string(from: last))")
        }
        return nil
    }

    /// Every "Month Day" / "Day Month" in the string, as start-of-day dates.
    private static func allMonthDays(_ lower: String, now: Date, calendar: Calendar) -> [Date] {
        let monthAlt = monthNumbers.keys.joined(separator: "|")
        let patterns = [#"\b(\#(monthAlt))\s+(\d{1,2})(?:st|nd|rd|th)?\b"#, #"\b(\d{1,2})(?:st|nd|rd|th)?\s+(\#(monthAlt))\b"#]
        var out: [Date] = []
        for (idx, pattern) in patterns.enumerated() {
            guard let rx = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = lower as NSString
            for m in rx.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
                let g1 = ns.substring(with: m.range(at: 1)); let g2 = ns.substring(with: m.range(at: 2))
                let monthStr = idx == 0 ? g1 : g2; let dayStr = idx == 0 ? g2 : g1
                guard let month = monthNumbers[monthStr], let day = Int(dayStr), (1...31).contains(day) else { continue }
                var comps = calendar.dateComponents([.year], from: now); comps.month = month; comps.day = day
                guard var dt = calendar.date(from: comps).map({ calendar.startOfDay(for: $0) }) else { continue }
                if dt > now, let prev = calendar.date(byAdding: .year, value: -1, to: dt) { dt = calendar.startOfDay(for: prev) }
                out.append(dt)
            }
        }
        return out
    }

    /// "last/past/previous N day(s)/week(s)" with N as a digit or a word.
    private static func matchRelativeRange(
        _ lower: String, now: Date, startOfToday: Date, calendar: Calendar
    ) -> DateScope? {
        let pattern = #"\b(?:last|past|previous)\s+(\d+|a|an|one|two|couple|three|few|four|several|five|six|seven|eight|nine|ten)\s+(day|days|week|weeks)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = lower as NSString
        guard let match = regex.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let numStr = ns.substring(with: match.range(at: 1))
        let unit = ns.substring(with: match.range(at: 2))
        let n = Int(numStr) ?? wordNumbers[numStr] ?? 1
        guard n > 0 else { return nil }
        let isWeek = unit.hasPrefix("week")
        let dayCount = isWeek ? n * 7 : n
        guard let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: startOfToday) else {
            return nil
        }
        let plural = n == 1 ? "" : "s"
        let label = isWeek ? "the last \(n) week\(plural)" : "the last \(n) day\(plural)"
        return DateScope(interval: DateInterval(start: start, end: now), label: label)
    }

    /// A specific "Month Day" / "Day Month" (e.g. "May 26", "26th May").
    private static func matchSpecificDate(_ lower: String, now: Date, calendar: Calendar) -> DateScope? {
        let monthAlt = monthNumbers.keys.joined(separator: "|")
        let patterns = [
            #"\b(\#(monthAlt))\s+(\d{1,2})(?:st|nd|rd|th)?\b"#,
            #"\b(\d{1,2})(?:st|nd|rd|th)?\s+(\#(monthAlt))\b"#,
        ]
        for (idx, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = lower as NSString
            guard let m = regex.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)) else {
                continue
            }
            let g1 = ns.substring(with: m.range(at: 1))
            let g2 = ns.substring(with: m.range(at: 2))
            let monthStr = idx == 0 ? g1 : g2
            let dayStr = idx == 0 ? g2 : g1
            guard let month = monthNumbers[monthStr], let day = Int(dayStr), (1...31).contains(day) else {
                continue
            }
            var comps = calendar.dateComponents([.year], from: now)
            comps.month = month
            comps.day = day
            guard var dayStart = calendar.date(from: comps).map({ calendar.startOfDay(for: $0) }) else {
                continue
            }
            if dayStart > now, let prevYear = calendar.date(byAdding: .year, value: -1, to: dayStart) {
                dayStart = calendar.startOfDay(for: prevYear)
            }
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let fmt = DateFormatter()
            fmt.dateFormat = "MMMM d"
            return DateScope(
                interval: DateInterval(start: dayStart, end: dayEnd),
                label: fmt.string(from: dayStart)
            )
        }
        return nil
    }

    /// Generic scaffolding / request / date words. When a date-scoped question
    /// contains nothing beyond these, it's a pure summary (rank chronologically);
    /// any remaining content word is the topic to rank by within the window.
    private static let queryScaffolding: Set<String> = [
        "what", "whats", "which", "who", "whom", "when", "where", "why", "how",
        "did", "do", "does", "doing", "done", "can", "could", "would", "should",
        "i", "ive", "im", "id", "me", "my", "mine", "we", "our", "you", "your",
        "the", "a", "an", "of", "from", "in", "on", "at", "by", "about", "around",
        "is", "are", "am", "was", "were", "be", "been", "being", "have", "has", "had",
        "that", "this", "these", "those", "there", "here", "it", "its",
        "and", "or", "but", "to", "for", "with", "without", "into", "over", "up",
        "get", "got", "any", "some", "more", "most",
        "no", "so", "go", "ok", "us", "oh", "hi", "if", "as", "back",
        "please", "just", "again", "really", "also", "then", "still", "like",
        "note", "notes", "record", "recorded", "recording", "recordings",
        "dictate", "dictated", "dictation", "say", "said", "saying", "speak",
        "spoke", "spoken", "talk", "talked", "talking", "jot", "jotted",
        "write", "wrote", "written", "capture", "captured", "thought", "thoughts",
        "summarize", "summarise", "summary", "give", "tell", "show", "list",
        "pull", "find", "recap", "review", "everything", "all", "anything",
        "something", "thing", "things", "stuff", "much", "many", "few",
        "today", "yesterday", "day", "days", "week", "weeks", "weekend",
        "month", "months", "year", "years", "morning", "afternoon", "evening",
        "tonight", "night", "last", "past", "previous", "next", "ago", "recent",
        "recently", "lately", "ever", "since", "between", "during", "until",
        "through", "early", "late", "end", "beginning", "start", "first",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    /// True when a date-scoped question carries a subject to rank by beyond the
    /// date/scaffolding words — so in-window notes are ranked by relevance
    /// (semantic) rather than chronology. Heuristic, deterministic.
    static func queryHasTopicBeyondDate(_ question: String) -> Bool {
        let tokens = question.lowercased().split { !$0.isLetter }.map(String.init)
        return tokens.contains { $0.count >= 2 && !queryScaffolding.contains($0) }
    }
}
