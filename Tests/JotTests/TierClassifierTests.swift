import Foundation
import Testing
@testable import Jot

/// Synthetic-input tests for `TierClassifier.defaultPick(among:)`.
/// Each test feeds a `[DiscoveredModel]` directly (bypassing the
/// probes' JSON parsing) so the generation-and-tier logic is
/// isolated from per-provider parsing.
@Suite(.serialized)
struct TierClassifierTests {

    // MARK: - OpenAI

    @Test func openAI_picksLatestGenMini() {
        // 5.1 is the highest version present; mini wins inside it.
        let probe = OpenAIProbe()
        let models = [
            DiscoveredModel(id: "gpt-4o",        tier: .medium),
            DiscoveredModel(id: "gpt-4o-mini",   tier: .small),
            DiscoveredModel(id: "gpt-5",         tier: .medium),
            DiscoveredModel(id: "gpt-5-mini",    tier: .small),
            DiscoveredModel(id: "gpt-5.1",       tier: .medium),
            DiscoveredModel(id: "gpt-5.1-nano",  tier: .small),
        ]
        // Tier classifier is queried via probe.discoverDefault — the
        // synthetic models above already carry tier hints, but the
        // classifier still re-checks `isThinking` and uses the
        // generation regex.
        let pick = probe.discoverDefault(probed: models)
        #expect(pick == "gpt-5.1-nano")
    }

    @Test func openAI_fallsBackToMidWhenNoMini() {
        let probe = OpenAIProbe()
        let models = [
            DiscoveredModel(id: "gpt-5", tier: .medium),
        ]
        let pick = probe.discoverDefault(probed: models)
        #expect(pick == "gpt-5")
    }

    // MARK: - Anthropic

    @Test func anthropic_picksHaikuOnLatestGen() {
        let probe = AnthropicProbe()
        let models = [
            DiscoveredModel(id: "claude-opus-4-5",    tier: .large),
            DiscoveredModel(id: "claude-sonnet-4-5",  tier: .medium),
            DiscoveredModel(id: "claude-haiku-4-5",   tier: .small),
            DiscoveredModel(id: "claude-haiku-3-5",   tier: .small),
        ]
        let pick = probe.discoverDefault(probed: models)
        #expect(pick == "claude-haiku-4-5")
    }

    @Test func anthropic_picksSonnetWhenHaikuMissing() {
        let probe = AnthropicProbe()
        let models = [
            DiscoveredModel(id: "claude-opus-4-5",    tier: .large),
            DiscoveredModel(id: "claude-sonnet-4-5",  tier: .medium),
        ]
        let pick = probe.discoverDefault(probed: models)
        #expect(pick == "claude-sonnet-4-5")
    }

    // MARK: - Gemini

    @Test func gemini_picksFlashLiteOnLatest() {
        let probe = GeminiProbe()
        let models = [
            DiscoveredModel(id: "gemini-2.5-flash",      tier: .medium),
            DiscoveredModel(id: "gemini-2.5-flash-lite", tier: .small),
            DiscoveredModel(id: "gemini-3.1-pro",        tier: .large),
            DiscoveredModel(id: "gemini-3.1-flash",      tier: .medium),
            DiscoveredModel(id: "gemini-3.1-flash-lite", tier: .small),
        ]
        let pick = probe.discoverDefault(probed: models)
        #expect(pick == "gemini-3.1-flash-lite")
    }

    @Test func gemini_picksFlashWhenLiteMissing() {
        let probe = GeminiProbe()
        let models = [
            DiscoveredModel(id: "gemini-3.1-flash", tier: .medium),
            DiscoveredModel(id: "gemini-3.1-pro",   tier: .large),
        ]
        let pick = probe.discoverDefault(probed: models)
        #expect(pick == "gemini-3.1-flash")
    }

    // MARK: - Edge cases

    @Test func emptyListReturnsNil() {
        #expect(OpenAIProbe().discoverDefault(probed: []) == nil)
        #expect(AnthropicProbe().discoverDefault(probed: []) == nil)
        #expect(GeminiProbe().discoverDefault(probed: []) == nil)
        #expect(OllamaProbe().discoverDefault(probed: []) == nil)
    }

    @Test func allThinkingReturnsNil() {
        // Every entry flagged as thinking — classifier should reject
        // the whole pool and return nil rather than picking a
        // thinking model as default.
        let probe = OpenAIProbe()
        let models = [
            DiscoveredModel(id: "gpt-5-thinking", isThinking: true, tier: .medium),
        ]
        let pick = probe.discoverDefault(probed: models)
        #expect(pick == nil)
    }

    @Test func ollamaPicksFirstWithoutVersionRegex() {
        let probe = OllamaProbe()
        let models = [
            DiscoveredModel(id: "first:7b"),
            DiscoveredModel(id: "second:13b"),
        ]
        let pick = probe.discoverDefault(probed: models)
        #expect(pick == "first:7b")
    }

    // MARK: - Generation key sortability

    @Test func generationKeyZeroPadsForLexCompare() {
        let classifier = OpenAIProbe().classifier
        let regex = classifier.latestGenRegex!
        let k4 = classifier.generationKey(for: "gpt-4o", regex: regex)
        let k5 = classifier.generationKey(for: "gpt-5", regex: regex)
        let k51 = classifier.generationKey(for: "gpt-5.1", regex: regex)
        let k10 = classifier.generationKey(for: "gpt-10", regex: regex)

        #expect(k4 != nil && k5 != nil && k51 != nil && k10 != nil)
        // Lexicographic ordering must match numeric ordering.
        #expect(k4! < k5!)
        #expect(k5! < k51!)
        #expect(k51! < k10!)  // 0010 > 0005.0001 lex.
    }

    @Test func anthropicGenerationKeyHandlesPair() {
        let classifier = AnthropicProbe().classifier
        let regex = classifier.latestGenRegex!
        let k45 = classifier.generationKey(for: "claude-haiku-4-5", regex: regex)
        let k35 = classifier.generationKey(for: "claude-haiku-3-5", regex: regex)
        let k30 = classifier.generationKey(for: "claude-haiku-3-0", regex: regex)
        // The Anthropic regex requires both numbers, so single-num
        // ids like `claude-opus-3` (legacy) won't match — that's OK,
        // they'll be skipped in the `withKeys` filter and not
        // picked as the default. The pair-form ids must sort
        // correctly relative to each other.
        #expect(k45 != nil)
        #expect(k35 != nil)
        #expect(k30 != nil)
        if let k45 = k45, let k35 = k35, let k30 = k30 {
            #expect(k45 > k35)
            #expect(k35 > k30)
        }
    }
}
