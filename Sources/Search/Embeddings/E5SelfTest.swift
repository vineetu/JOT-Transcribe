#if DEBUG
import AppKit
import Foundation

/// DEBUG harness: checks the Swift side of e5 against the Python reference.
///
///     JOT_E5_SELFTEST=<fixtures.json> [JOT_E5_SELFTEST_OUT=<report.txt>] Jot
///
/// Each fixture carries the role, text, the token ids Hugging Face's Python
/// tokenizer produced, and the embedding the same Core ML model produced from
/// those ids. For every fixture this compares (1) swift-transformers' token
/// ids — its XLM-R normaliser is an approximation, so this is the real risk —
/// and (2) the cosine between the Swift embedding and the reference. Writes a
/// report and exits 0 when every embedding matches (cos ≥ 0.999), else 1.
/// Uses the installed model; downloads it first if missing.
enum E5SelfTest {
    private struct Fixture: Decodable {
        let role: String
        let text: String
        let ids: [Int]
        let embedding: [Float]
    }

    @MainActor
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["JOT_E5_SELFTEST"] else { return }
        let out = env["JOT_E5_SELFTEST_OUT"]
        Task.detached {
            let (report, passed) = await run(fixtures: URL(fileURLWithPath: path))
            if let out { try? report.write(toFile: out, atomically: true, encoding: .utf8) }
            print(report)
            exit(passed ? 0 : 1)
        }
    }

    private static func run(fixtures url: URL) async -> (String, Bool) {
        var lines: [String] = []
        do {
            let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
            var allPassed = true
            var idMismatches = 0
            for f in fixtures {
                let role: E5EmbeddingService.Role = f.role == "query" ? .query : .document
                let ids = try await E5EmbeddingService.shared.tokenIDs(f.text, role: role)
                let vector = try await E5EmbeddingService.shared.encode(f.text, role: role)
                let cos = zip(vector, f.embedding).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                let idsMatch = ids == f.ids
                if !idsMatch { idMismatches += 1 }
                let ok = cos >= 0.999
                allPassed = allPassed && ok
                var line = String(format: "%@ cos=%.5f ids=%@ %@", ok ? "PASS" : "FAIL", cos,
                                  idsMatch ? "same" : "DIFF", String(f.text.prefix(48)).debugDescription)
                if !idsMatch {
                    let at = (0..<min(ids.count, f.ids.count)).first { ids[$0] != f.ids[$0] } ?? min(ids.count, f.ids.count)
                    line += " first diff at \(at): swift=\(ids.dropFirst(at).prefix(4)) py=\(f.ids.dropFirst(at).prefix(4)) (lengths \(ids.count)/\(f.ids.count))"
                }
                lines.append(line)
            }
            lines.append("\(fixtures.count) fixtures, \(idMismatches) token-id mismatches → \(allPassed ? "OK" : "FAILED")")
            return (lines.joined(separator: "\n"), allPassed)
        } catch {
            lines.append("ERROR \(error)")
            return (lines.joined(separator: "\n"), false)
        }
    }
}
#endif
