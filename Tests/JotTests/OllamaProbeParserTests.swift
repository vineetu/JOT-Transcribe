import Foundation
import Testing
@testable import Jot

/// Fixture-driven parser tests for `OllamaProbe.parse(data:)` and
/// `OllamaProbe.stripOpenAICompatSuffix(from:)`. JSON mirrors Ollama's
/// documented `/api/tags` response; no network.
@Suite(.serialized)
struct OllamaProbeParserTests {

    @Test func parsesAllPulledModels() {
        let json = #"""
        {
          "models": [
            {
              "name": "llama3.1:8b",
              "model": "llama3.1:8b",
              "modified_at": "2026-01-01T00:00:00Z",
              "size": 4661211808,
              "digest": "abc",
              "details": { "format": "gguf", "family": "llama", "parameter_size": "8.0B" }
            },
            {
              "name": "gemma2:27b",
              "model": "gemma2:27b",
              "modified_at": "2026-01-01T00:00:00Z",
              "size": 16000000000,
              "digest": "def",
              "details": { "format": "gguf", "family": "gemma", "parameter_size": "27B" }
            },
            {
              "name": "qwen2.5-coder:14b",
              "model": "qwen2.5-coder:14b",
              "modified_at": "2026-01-01T00:00:00Z",
              "size": 9000000000,
              "digest": "ghi",
              "details": { "format": "gguf", "family": "qwen2", "parameter_size": "14B" }
            }
          ]
        }
        """#
        let models = OllamaProbe.parse(data: Data(json.utf8))
        let ids = Set(models.map { $0.id })
        #expect(ids == ["llama3.1:8b", "gemma2:27b", "qwen2.5-coder:14b"])
        // No tier classification for Ollama (no consistent scheme
        // across families).
        for model in models {
            #expect(model.tier == nil)
            #expect(model.isThinking == false)
        }
    }

    @Test func emptyCatalogYieldsEmptyResult() {
        let models = OllamaProbe.parse(data: Data(#"{ "models": [] }"#.utf8))
        #expect(models.isEmpty)
    }

    @Test func defaultPickReturnsFirstId() {
        let json = #"""
        {
          "models": [
            { "name": "alpha:7b",  "model": "alpha:7b",  "modified_at": "0", "size": 0, "digest": "", "details": {} },
            { "name": "beta:13b",  "model": "beta:13b",  "modified_at": "0", "size": 0, "digest": "", "details": {} }
          ]
        }
        """#
        let models = OllamaProbe.parse(data: Data(json.utf8))
        // Sorted output, so "alpha" < "beta" — alpha:7b wins.
        let pick = OllamaProbe().discoverDefault(probed: models)
        #expect(pick == "alpha:7b")
    }

    @Test func stripsOpenAICompatSuffix() {
        #expect(OllamaProbe.stripOpenAICompatSuffix(from: "http://localhost:11434/v1") == "http://localhost:11434")
        #expect(OllamaProbe.stripOpenAICompatSuffix(from: "http://localhost:11434/v1/") == "http://localhost:11434")
        #expect(OllamaProbe.stripOpenAICompatSuffix(from: "http://localhost:11434") == "http://localhost:11434")
        #expect(OllamaProbe.stripOpenAICompatSuffix(from: "http://corp.example/proxy/v1") == "http://corp.example/proxy")
        #expect(OllamaProbe.stripOpenAICompatSuffix(from: "http://corp.example/proxy") == "http://corp.example/proxy")
    }
}
