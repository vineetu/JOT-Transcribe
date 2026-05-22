import Foundation
import Testing
@testable import Jot

/// Fixture-driven parser tests for `OpenAIProbe.parse(data:)`. No
/// network calls — JSON literals in this file mirror the shape of
/// OpenAI's documented `/v1/models` response, sanitized.
///
/// Asserts the per-provider filter rules from
/// `docs/plans/ai-provider-model-discovery.md`:
///
///   • Allowlist: `^gpt-`.
///   • Blocklist: whisper, tts, dall-e, image, text-embedding,
///     babbage, davinci, audio, realtime, transcribe.
///   • Tier classification on the discovered ids (`-mini` /
///     `-nano` → small; bare → medium; `-pro` → large).
@Suite(.serialized)
struct OpenAIProbeParserTests {

    @Test func parsesChatModelsAndFiltersBlocklist() throws {
        let json = #"""
        {
          "object": "list",
          "data": [
            { "id": "gpt-5",         "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "gpt-5-mini",    "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "gpt-5-nano",    "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "gpt-4o",        "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "gpt-4o-mini",   "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "whisper-1",     "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "tts-1",         "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "dall-e-3",      "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "text-embedding-3-small", "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "babbage-002",   "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "davinci-002",   "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "gpt-4o-audio-preview",     "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "gpt-4o-realtime-preview",  "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "gpt-4o-transcribe",        "object": "model", "created": 0, "owned_by": "openai" }
          ]
        }
        """#
        let models = OpenAIProbe.parse(data: Data(json.utf8))
        let ids = Set(models.map { $0.id })

        // Kept:
        #expect(ids == [
            "gpt-5",
            "gpt-5-mini",
            "gpt-5-nano",
            "gpt-4o",
            "gpt-4o-mini",
        ])

        // Tiers tagged correctly.
        let byId = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        #expect(byId["gpt-5-mini"]?.tier == .small)
        #expect(byId["gpt-5-nano"]?.tier == .small)
        #expect(byId["gpt-5"]?.tier == .medium)
        #expect(byId["gpt-4o"]?.tier == .medium)
        #expect(byId["gpt-4o-mini"]?.tier == .small)
    }

    @Test func dropsThinkingModels() throws {
        let json = #"""
        {
          "object": "list",
          "data": [
            { "id": "gpt-5-thinking", "object": "model", "created": 0, "owned_by": "openai" },
            { "id": "gpt-5-mini",     "object": "model", "created": 0, "owned_by": "openai" }
          ]
        }
        """#
        let models = OpenAIProbe.parse(data: Data(json.utf8))
        // We keep `-thinking` in the list (it's still chat-capable),
        // but flag it as `isThinking: true` so the default-pick logic
        // skips it.
        #expect(models.contains(where: { $0.id == "gpt-5-thinking" && $0.isThinking }))
        // Default selection should not be the thinking model.
        let pick = OpenAIProbe().discoverDefault(probed: models)
        #expect(pick == "gpt-5-mini")
    }

    @Test func emptyDataYieldsEmptyResult() {
        let models = OpenAIProbe.parse(data: Data(#"{ "data": [] }"#.utf8))
        #expect(models.isEmpty)
    }

    @Test func malformedJsonYieldsEmptyResult() {
        let models = OpenAIProbe.parse(data: Data("not json".utf8))
        #expect(models.isEmpty)
    }
}
