import Foundation

/// Pure, UI-free model for the recording-detail AI summary feature: the summary
/// "kinds" (which prompt to run), the context-smart menu (speaker count → which
/// kinds to offer), the labeled-transcript serialization fed to the LLM, and the
/// capable-provider gate. No SwiftUI, no LLM client — the view/prompt layers
/// consume these.
enum SummaryKind: String, Equatable, CaseIterable {
    // Multi-speaker (diarized ≥ 2 speakers) actions.
    case meetingSummary
    case actionItems
    case keyDecisions
    // Single-speaker actions.
    case summary
    case keyPoints
    // Free-form user instruction.
    case custom

    /// Menu / section-header label.
    var title: String {
        switch self {
        case .meetingSummary: return "Meeting summary"
        case .actionItems:    return "Action items"
        case .keyDecisions:   return "Key decisions"
        case .summary:        return "Summary"
        case .keyPoints:      return "Key points"
        case .custom:         return "Custom"
        }
    }
}

/// Context-smart menu: which built-in actions to offer given the recording's
/// speaker count. "Custom prompt…" is appended by the view (it's not a
/// transcript-derived choice). Two or more distinct speakers ⇒ meeting actions;
/// otherwise the single-note actions.
enum SummaryMenu {
    static let meetingActions: [SummaryKind] = [.meetingSummary, .actionItems, .keyDecisions]
    static let singleActions: [SummaryKind] = [.summary, .keyPoints]

    static func actions(speakerCount: Int) -> [SummaryKind] {
        speakerCount >= 2 ? meetingActions : singleActions
    }
}

/// Builds the transcript text fed to the summary LLM.
enum SummaryInput {
    /// Distinct speaker labels in a decoded timeline (0 when none / not diarized).
    static func speakerCount(segments: [SpeakerTimelineSegment]?) -> Int {
        guard let segments else { return 0 }
        return Set(segments.map(\.speakerLabel)).count
    }

    /// Labeled transcript for a diarized recording — one `"Label: text"` line per
    /// coalesced display run (the SAME grouping the labeled view shows; labels are
    /// the resolved names, including per-recording renames). Lets the model
    /// attribute action items / decisions to a speaker. Empty-text runs are
    /// dropped by `coalesceDisplayRuns`.
    static func labeledTranscript(segments: [SpeakerTimelineSegment]) -> String {
        SpeakerTimelineBuilder.coalesceDisplayRuns(segments)
            .map { "\($0.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
    }
}

/// The capable-provider gate (owner rule): summaries route ONLY to capable
/// providers (OpenAI / Anthropic / Gemini / Ollama / LM Studio — anything that is
/// NOT on-device Apple Intelligence), and only when that provider is actually
/// configured. Apple Intelligence is refused outright — never routed to.
enum SummaryAvailability {

    /// True when a summary can run: the selected provider is capable (not Apple
    /// Intelligence) AND it's minimally configured (key / endpoint present).
    static func isEnabled(provider: LLMProvider, isMinimallyConfigured: Bool) -> Bool {
        provider != .appleIntelligence && isMinimallyConfigured
    }

    /// The user-facing reason the button is disabled, or `nil` when enabled.
    static func disabledReason(provider: LLMProvider, isMinimallyConfigured: Bool) -> String? {
        if provider == .appleIntelligence {
            return "Summaries need a more capable model than Apple Intelligence. "
                + "Choose a cloud or local provider in Settings → AI."
        }
        if !isMinimallyConfigured {
            return "Set up a cloud or local provider in Settings → AI to generate summaries."
        }
        return nil
    }
}
