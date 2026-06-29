import SwiftUI

/// **Review Jot's Corrections — the summary-row + accordion** (the "review them
/// all here" surface) for `RecordingDetailView`. Per OCCURRENCE, shows every
/// word the gate changed (`CHANGED`) or kept (`KEPT`) and lets the owner
/// adjudicate by **picking the word they meant** (never yes/no). State + actions
/// live in the shared `CorrectionReviewModel`.
///
/// **Ported from jot-mobile** (`Jot/App/Vocabulary/CorrectionReviewSection.swift`).
/// MVP adaptations:
///   - iOS card chrome → a macOS `GroupBox` + `DisclosureGroup`, matching the
///     transcript block in `RecordingDetailView`.
///   - iPhone design tokens (`jotAccent` / `jotPageInk` / `Color(uiColor:)`) →
///     native semantic colors (`.accentColor` / `.primary` / `.secondary` /
///     `Color(nsColor:)`).
///   - Dropped the `CorrectionBubble` (in-text caret bubble) and the "Show N
///     more" cap — deferred (review-ux.md §1/§6 "Later"). All rows render.
struct CorrectionReviewSection: View {
    @Bindable var model: CorrectionReviewModel

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $model.accordionExpanded) {
                reviewBody
                    .padding(.top, 10)
            } label: {
                summaryLabel
            }
        }
    }

    // MARK: - Summary label

    private var summaryLabel: some View {
        HStack(spacing: 8) {
            if model.allReviewed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 13))
            } else {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 13))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.allReviewed
                    ? "All reviewed"
                    : "Jot guessed on \(model.records.count) word\(model.records.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                if !model.allReviewed {
                    Text("Pick the word you meant.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        // Let a click anywhere on the summary row toggle the accordion, not just
        // the disclosure chevron. `contentShape` makes the whole row (including
        // the trailing spacer) hit-testable.
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                model.accordionExpanded.toggle()
            }
        }
    }

    // MARK: - Review body

    private var reviewBody: some View {
        let rows = Array(model.records.enumerated())
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.element.key) { idx, r in
                row(r).padding(.vertical, 10)
                if idx != rows.count - 1 {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ r: CorrectionProvenance.Record) -> some View {
        if let verdict = model.verdict(of: r) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                CorrectionCopy.resolvedText(r, verdict: verdict)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                Spacer(minLength: 8)
                Button("Undo") { Task { await model.undo(r) } }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                // Spoken context first — so when several rows share a word ("name"),
                // the owner can tell WHICH occurrence each row is about.
                if let ctx = model.context(for: r) {
                    contextLine(ctx)
                }
                CorrectionRowHeader(record: r)
                CorrectionChips(record: r) { choice in Task { await model.pick(r, choice: choice) } }
            }
        }
    }

    /// The spoken line for a row — italic serif, with the gated word emphasized
    /// + dash-underlined so it's findable in the snippet.
    private func contextLine(_ ctx: (before: String, gated: String, after: String)) -> some View {
        (Text(ctx.before).foregroundColor(.secondary)
            + Text(ctx.gated).foregroundColor(.primary)
                .underline(true, pattern: .dash, color: .secondary)
            + Text(ctx.after).foregroundColor(.secondary))
            .font(.system(size: 12.5, design: .serif).italic())
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Shared atoms

/// Badge + "Original …" note row.
struct CorrectionRowHeader: View {
    let record: CorrectionProvenance.Record
    var body: some View {
        let applied = (record.outcome == "applied")
        HStack(spacing: 8) {
            Text(applied ? "CHANGED" : "KEPT")
                .font(.system(size: 9, weight: .bold)).tracking(1.1)
                .foregroundStyle(applied ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(
                    applied
                        ? AnyView(Capsule().fill(Color.accentColor.opacity(0.18)))
                        : AnyView(Capsule().fill(Color.secondary.opacity(0.12))
                            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))))
            (Text("Original ").foregroundStyle(.secondary)
                + Text("\u{201C}\(record.originalWord)\u{201D}").foregroundStyle(.primary))
                .font(.system(size: 11.5))
            Spacer(minLength: 0)
        }
    }
}

/// The two "pick the word you meant" chips (original first; in-text one tagged).
struct CorrectionChips: View {
    let record: CorrectionProvenance.Record
    var onPick: (String) -> Void
    var body: some View {
        let applied = (record.outcome == "applied")
        // A word must never wrap mid-word inside a chip. Try the two chips
        // side-by-side; if they don't fit, STACK them rather than break a name.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chip(record.originalWord, inText: !applied) { onPick("original") }
                                 chip(record.term, inText: applied) { onPick("term") } }
            VStack(alignment: .leading, spacing: 8) { chip(record.originalWord, inText: !applied) { onPick("original") }
                                                      chip(record.term, inText: applied) { onPick("term") } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ word: String, inText: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(word).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                if inText {
                    Text("IN TEXT").font(.system(size: 8, weight: .bold)).tracking(0.8)
                        .foregroundStyle(.secondary).fixedSize()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

enum CorrectionCopy {
    /// Resolved-row copy split into a BOLD lead segment + secondary rest.
    static func resolvedParts(_ r: CorrectionProvenance.Record, verdict: String) -> (strong: String, rest: String) {
        let applied = (r.outcome == "applied")
        if verdict == "term" {
            return applied
                ? (r.term, " confirmed.")
                : (r.term, " applied here.")
        }
        return applied
            ? (r.originalWord, " restored.")
            : (r.originalWord, " kept.")
    }

    /// Concatenated `Text`: bold term lead in primary ink + rest in secondary.
    static func resolvedText(_ r: CorrectionProvenance.Record, verdict: String) -> Text {
        let p = resolvedParts(r, verdict: verdict)
        return Text(p.strong).font(.system(size: 12, weight: .semibold)).foregroundColor(.primary)
            + Text(p.rest).foregroundColor(.secondary)
    }
}
