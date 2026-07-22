#if DEBUG
import Foundation

/// DEBUG-only runtime tests for the pure summary helpers (context-smart menu,
/// labeled-transcript serialization, capable-provider gate). Same
/// `assert()`-in-`#if DEBUG` idiom as the other in-app harnesses; runs once at
/// startup via `runAll()` and is stripped from release builds.
enum RecordingSummaryTests {

    static func runAll() {
        test_menuContextSmart()
        test_speakerCount()
        test_labeledTranscriptSerialization()
        test_providerGate_appleIntelligenceDisabled()
        test_providerGate_capableConfiguredEnabled()
        test_providerGate_capableUnconfiguredDisabled()
    }

    private static func seg(_ label: String, _ text: String) -> SpeakerTimelineSegment {
        SpeakerTimelineSegment(speakerLabel: label, startSec: 0, endSec: 1, text: text)
    }

    static func test_menuContextSmart() {
        assert(SummaryMenu.actions(speakerCount: 0) == [.summary, .keyPoints], "0 speakers → single actions")
        assert(SummaryMenu.actions(speakerCount: 1) == [.summary, .keyPoints], "1 speaker → single actions")
        assert(SummaryMenu.actions(speakerCount: 2) == [.meetingSummary, .actionItems, .keyDecisions], "2 → meeting")
        assert(SummaryMenu.actions(speakerCount: 5) == [.meetingSummary, .actionItems, .keyDecisions], "5 → meeting")
    }

    static func test_speakerCount() {
        assert(SummaryInput.speakerCount(segments: nil) == 0, "nil → 0")
        let segs = [seg("Speaker 1", "hi"), seg("Speaker 2", "hello"), seg("Speaker 1", "bye")]
        assert(SummaryInput.speakerCount(segments: segs) == 2, "two distinct labels → 2, got \(SummaryInput.speakerCount(segments: segs))")
    }

    static func test_labeledTranscriptSerialization() {
        // Consecutive same-label runs coalesce; each display run → "Label: text".
        let segs = [
            seg("Alex", "Let's start."),
            seg("Alex", "First topic is budget."),
            seg("Sam", "I disagree."),
        ]
        let out = SummaryInput.labeledTranscript(segments: segs)
        assert(out == "Alex: Let's start. First topic is budget.\nSam: I disagree.",
               "labeled serialization mismatch, got:\n\(out)")
    }

    static func test_providerGate_appleIntelligenceDisabled() {
        assert(SummaryAvailability.isEnabled(provider: .appleIntelligence, isMinimallyConfigured: true) == false,
               "Apple Intelligence must be refused even when 'configured'")
        let reason = SummaryAvailability.disabledReason(provider: .appleIntelligence, isMinimallyConfigured: true)
        assert(reason?.contains("Apple Intelligence") == true, "AI disabled reason should name Apple Intelligence, got \(reason ?? "nil")")
    }

    static func test_providerGate_capableConfiguredEnabled() {
        assert(SummaryAvailability.isEnabled(provider: .openai, isMinimallyConfigured: true), "openai+configured → enabled")
        assert(SummaryAvailability.disabledReason(provider: .anthropic, isMinimallyConfigured: true) == nil, "no reason when enabled")
        assert(SummaryAvailability.isEnabled(provider: .ollama, isMinimallyConfigured: true), "ollama (local) → enabled")
    }

    static func test_providerGate_capableUnconfiguredDisabled() {
        assert(SummaryAvailability.isEnabled(provider: .openai, isMinimallyConfigured: false) == false, "unconfigured cloud → disabled")
        let reason = SummaryAvailability.disabledReason(provider: .openai, isMinimallyConfigured: false)
        assert(reason?.contains("Settings → AI") == true, "unconfigured reason should point to Settings → AI, got \(reason ?? "nil")")
    }
}
#endif
