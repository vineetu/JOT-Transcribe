import Foundation
import Testing
@testable import Jot

/// Fixture-driven parser tests for `AnthropicProbe.parse(data:)`.
/// JSON mirrors Anthropic's documented `/v1/models` shape; no
/// network involved.
@Suite(.serialized)
struct AnthropicProbeParserTests {

    @Test func parsesClaudeIdsWithDisplayName() throws {
        let json = #"""
        {
          "data": [
            { "type": "model", "id": "claude-opus-4-5",    "display_name": "Claude Opus 4.5",   "created_at": "2026-01-15T00:00:00Z" },
            { "type": "model", "id": "claude-sonnet-4-5",  "display_name": "Claude Sonnet 4.5", "created_at": "2026-01-15T00:00:00Z" },
            { "type": "model", "id": "claude-haiku-4-5",   "display_name": "Claude Haiku 4.5",  "created_at": "2026-01-15T00:00:00Z" },
            { "type": "model", "id": "claude-haiku-3-5",   "display_name": "Claude Haiku 3.5",  "created_at": "2025-01-01T00:00:00Z" },
            { "type": "model", "id": "claude-opus-3",      "display_name": "Claude Opus 3",     "created_at": "2024-01-01T00:00:00Z" }
          ],
          "has_more": false,
          "first_id": "claude-opus-4-5",
          "last_id": "claude-opus-3"
        }
        """#
        let models = AnthropicProbe.parse(data: Data(json.utf8))
        #expect(models.count == 5)

        let byId = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        #expect(byId["claude-haiku-4-5"]?.tier == .small)
        #expect(byId["claude-sonnet-4-5"]?.tier == .medium)
        #expect(byId["claude-opus-4-5"]?.tier == .large)
        #expect(byId["claude-haiku-4-5"]?.displayName == "Claude Haiku 4.5")
    }

    @Test func picksHaikuOnLatestGeneration() {
        let json = #"""
        {
          "data": [
            { "type": "model", "id": "claude-opus-4-5",    "display_name": "Opus 4.5", "created_at": "0" },
            { "type": "model", "id": "claude-sonnet-4-5",  "display_name": "Sonnet 4.5", "created_at": "0" },
            { "type": "model", "id": "claude-haiku-4-5",   "display_name": "Haiku 4.5", "created_at": "0" },
            { "type": "model", "id": "claude-opus-3",      "display_name": "Opus 3", "created_at": "0" }
          ]
        }
        """#
        let models = AnthropicProbe.parse(data: Data(json.utf8))
        let pick = AnthropicProbe().discoverDefault(probed: models)
        #expect(pick == "claude-haiku-4-5")
    }

    @Test func dropsNonClaudeEntries() {
        let json = #"""
        {
          "data": [
            { "type": "model", "id": "claude-haiku-4-5", "display_name": "Haiku 4.5", "created_at": "0" },
            { "type": "model", "id": "gpt-4o",           "display_name": "GPT-4o",   "created_at": "0" }
          ]
        }
        """#
        let models = AnthropicProbe.parse(data: Data(json.utf8))
        #expect(models.map { $0.id } == ["claude-haiku-4-5"])
    }
}
