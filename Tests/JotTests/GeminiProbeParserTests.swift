import Foundation
import Testing
@testable import Jot

/// Fixture-driven parser tests for `GeminiProbe.parse(data:)`. JSON
/// mirrors Gemini's documented `/v1beta/models` shape; no network.
@Suite(.serialized)
struct GeminiProbeParserTests {

    @Test func parsesAndFiltersToGenerateContent() throws {
        let json = #"""
        {
          "models": [
            {
              "name": "models/gemini-3.1-flash-lite",
              "displayName": "Gemini 3.1 Flash Lite",
              "supportedGenerationMethods": ["generateContent", "countTokens"]
            },
            {
              "name": "models/gemini-3.1-flash",
              "displayName": "Gemini 3.1 Flash",
              "supportedGenerationMethods": ["generateContent", "countTokens"]
            },
            {
              "name": "models/gemini-3.1-pro",
              "displayName": "Gemini 3.1 Pro",
              "supportedGenerationMethods": ["generateContent", "countTokens"]
            },
            {
              "name": "models/embedding-001",
              "displayName": "Embedding 001",
              "supportedGenerationMethods": ["embedContent"]
            },
            {
              "name": "models/text-bison-001",
              "displayName": "Text Bison",
              "supportedGenerationMethods": ["generateText"]
            }
          ]
        }
        """#
        let models = GeminiProbe.parse(data: Data(json.utf8))
        let ids = Set(models.map { $0.id })

        // Dropped: embedding-001 (not gemini-), text-bison (not
        // gemini- AND doesn't have generateContent).
        #expect(ids == [
            "gemini-3.1-flash-lite",
            "gemini-3.1-flash",
            "gemini-3.1-pro",
        ])

        let byId = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        #expect(byId["gemini-3.1-flash-lite"]?.tier == .small)
        #expect(byId["gemini-3.1-flash"]?.tier == .medium)
        #expect(byId["gemini-3.1-pro"]?.tier == .large)
    }

    @Test func picksFlashLiteOnLatestGeneration() {
        let json = #"""
        {
          "models": [
            { "name": "models/gemini-2.5-flash-lite", "displayName": "2.5 Flash Lite", "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/gemini-2.5-flash",      "displayName": "2.5 Flash",      "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/gemini-3.1-flash-lite", "displayName": "3.1 Flash Lite", "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/gemini-3.1-flash",      "displayName": "3.1 Flash",      "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/gemini-3.1-pro",        "displayName": "3.1 Pro",        "supportedGenerationMethods": ["generateContent"] }
          ]
        }
        """#
        let models = GeminiProbe.parse(data: Data(json.utf8))
        let pick = GeminiProbe().discoverDefault(probed: models)
        #expect(pick == "gemini-3.1-flash-lite")
    }

    @Test func excludesThinkingModels() {
        let json = #"""
        {
          "models": [
            { "name": "models/gemini-3.1-flash-lite",         "displayName": "Flash Lite", "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/gemini-3.1-flash-thinking",     "displayName": "Flash Thinking", "supportedGenerationMethods": ["generateContent"] }
          ]
        }
        """#
        let models = GeminiProbe.parse(data: Data(json.utf8))
        // Both stay in the list, but `-thinking` is flagged.
        let thinking = models.first(where: { $0.id == "gemini-3.1-flash-thinking" })
        #expect(thinking?.isThinking == true)
        // Default pick avoids the thinking entry.
        let pick = GeminiProbe().discoverDefault(probed: models)
        #expect(pick == "gemini-3.1-flash-lite")
    }
}
