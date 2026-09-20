#!/usr/bin/env swift

// generate-fragments.swift
//
// Build Phase 1 of the grounding-doc pipeline (spec v5 §11).
//
// Reads the Swift single-source-of-truth enums and structs from
// `Sources/LLM/GroundingDocFacts.swift` and emits short markdown stanzas
// under `Resources/fragments/`, one file per named fragment used by
// `Resources/help-content-base.md`.
//
// Keep this script self-contained and dependency-free — it runs via
// `swift tools/generate-fragments.swift` at build time. Parsing the
// source file (rather than importing the enums) avoids a module-level
// dependency on the app target and lets Xcode run us before the Swift
// compile step.
//
// If a fragment is ever added or removed, update:
//   * This script's `fragments` map, AND
//   * The `<!-- FRAGMENT: name -->` placeholders in
//     `Resources/help-content-base.md`.
// The concat step (step 2) fails if any placeholder is unmatched.

import Foundation

// MARK: - Paths

// Xcode sets SRCROOT to the project directory. When run manually from
// the repo root (`swift tools/generate-fragments.swift`) we fall back
// to the current directory.
let repoRoot: URL = {
    if let srcroot = ProcessInfo.processInfo.environment["SRCROOT"] {
        return URL(fileURLWithPath: srcroot)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}()

let factsFile = repoRoot
    .appendingPathComponent("Sources")
    .appendingPathComponent("LLM")
    .appendingPathComponent("GroundingDocFacts.swift")

let fragmentsDir = repoRoot
    .appendingPathComponent("Resources")
    .appendingPathComponent("fragments")

// MARK: - Source parsing

guard let source = try? String(contentsOf: factsFile, encoding: .utf8) else {
    FileHandle.standardError.write("generate-fragments: cannot read \(factsFile.path)\n".data(using: .utf8)!)
    exit(1)
}

/// Extract the body between `enum <name>: ... {` and the matching
/// closing brace at the top level of the enum. Returns nil if not found.
func enumBody(_ name: String, in text: String) -> String? {
    // `enum <name>[^{]*\{ <body> \n}` — match up to the line-starting "}"
    let pattern = #"enum\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s*:[^\{]*\{([\s\S]*?)\n\}"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let bodyRange = Range(match.range(at: 1), in: text) else {
        return nil
    }
    return String(text[bodyRange])
}

/// Parse `case <symbol> = "<raw>"` and `case <symbol>` lines into
/// (symbol, rawValue) pairs. rawValue falls back to symbol when no `=` present.
///
/// Only accepts enum declarations — skips switch `case .foo:` pattern lines
/// (which contain a leading `.` and a trailing `:`) so computed properties
/// embedded in the enum body don't pollute the output.
func parseCases(_ body: String) -> [(symbol: String, raw: String)] {
    var results: [(String, String)] = []
    let lines = body.components(separatedBy: .newlines)
    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("case ") else { continue }
        let afterCase = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        // Skip switch-statement cases: `case .foo:` or `case .foo, .bar:`.
        if afterCase.hasPrefix(".") || afterCase.hasSuffix(":") || afterCase.contains(": return") {
            continue
        }
        // Support comma-separated: `case en, fr, de, ...`
        if !afterCase.contains("=") {
            let symbols = afterCase
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for sym in symbols {
                results.append((sym, sym))
            }
            continue
        }
        // Single case with `= "..."` or `= <int>` — extract raw value.
        if let eqIdx = afterCase.firstIndex(of: "=") {
            let symbol = afterCase[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let rest = afterCase[afterCase.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\""), let closeQuote = rest.dropFirst().firstIndex(of: "\"") {
                let raw = String(rest[rest.index(after: rest.startIndex)..<closeQuote])
                results.append((symbol, raw))
            } else {
                results.append((symbol, rest))
            }
        }
    }
    return results
}

/// Extract a `static let <name> = "<value>"` literal from a struct body.
func staticLetString(_ symbol: String, in body: String) -> String? {
    let pattern = #"static\s+let\s+"# + NSRegularExpression.escapedPattern(for: symbol) + #"\s*=\s*"([^"]*)""#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
          let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: body) else {
        return nil
    }
    return String(body[range])
}

/// Extract the contents of the `static let all: [ProviderCostEstimate] = [ ... ]` array literal.
/// Returns tuples of (provider, monthlyEstimate).
func parseProviderCosts(in text: String) -> [(provider: String, cost: String)] {
    // Look for .init(provider: "X", monthlyEstimate: "Y")
    let pattern = #"\.init\(provider:\s*"([^"]+)"\s*,\s*monthlyEstimate:\s*"([^"]+)"\s*\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    return matches.compactMap { m -> (String, String)? in
        guard m.numberOfRanges >= 3 else { return nil }
        let p = ns.substring(with: m.range(at: 1))
        let c = ns.substring(with: m.range(at: 2))
        return (p, c)
    }
}

// MARK: - Source data

guard let v3LangBody = enumBody("Parakeetv3DetectedLanguage", in: source) else {
    FileHandle.standardError.write("generate-fragments: missing Parakeetv3DetectedLanguage enum\n".data(using: .utf8)!)
    exit(1)
}
let languages = parseCases(v3LangBody).map { $0.raw }

guard let jotASRLangBody = enumBody("JotASRLanguage", in: source) else {
    FileHandle.standardError.write("generate-fragments: missing JotASRLanguage enum\n".data(using: .utf8)!)
    exit(1)
}
// Map symbol → user-facing label. Each `JotASRLanguage` case corresponds
// to a Parakeet model the user can install as primary.
let jotASRLabels: [String: String] = [
    "english":  "English (English-optimized on-device model; the language picker covers 25+ more languages)",
    "japanese": "Japanese (Parakeet 0.6B JA, separate ~1.25 GB download)",
]
let jotASRLanguages = parseCases(jotASRLangBody).map { jotASRLabels[$0.symbol] ?? $0.symbol }

guard let cleanupBody = enumBody("CleanupPass", in: source) else {
    FileHandle.standardError.write("generate-fragments: missing CleanupPass enum\n".data(using: .utf8)!)
    exit(1)
}
let cleanupPasses = parseCases(cleanupBody).map { $0.raw }

guard let invariantBody = enumBody("RewriteInvariant", in: source) else {
    FileHandle.standardError.write("generate-fragments: missing RewriteInvariant enum\n".data(using: .utf8)!)
    exit(1)
}
let invariants = parseCases(invariantBody).map { $0.raw }

// RewriteBranch lives in RewriteInstructionClassifier.swift.
let branchFile = repoRoot
    .appendingPathComponent("Sources").appendingPathComponent("LLM")
    .appendingPathComponent("RewriteInstructionClassifier.swift")
guard let branchSource = try? String(contentsOf: branchFile, encoding: .utf8),
      let branchBody = enumBody("RewriteBranch", in: branchSource) else {
    FileHandle.standardError.write("generate-fragments: missing RewriteBranch enum\n".data(using: .utf8)!)
    exit(1)
}
// Branch cases have no explicit raw value; map the symbol to a human label.
let branchSymbols = parseCases(branchBody).map { $0.symbol }
let branchLabels: [String: String] = [
    "voicePreserving": "voice-preserving",
    "structural":      "structural",
    "translation":     "translation",
    "code":            "code",
]
let branches = branchSymbols.map { branchLabels[$0] ?? $0 }

// RetentionPeriod — int raw values, map via label helper baked into struct.
guard let retentionBody = enumBody("RetentionPeriod", in: source) else {
    FileHandle.standardError.write("generate-fragments: missing RetentionPeriod enum\n".data(using: .utf8)!)
    exit(1)
}
let retentionSymbols = parseCases(retentionBody).map { $0.symbol }
let retentionLabels: [String: String] = [
    "sevenDays":  "7 days",
    "thirtyDays": "30 days",
    "ninetyDays": "90 days",
    "forever":    "forever",
]
let retention = retentionSymbols.map { retentionLabels[$0] ?? $0 }

// DefaultShortcuts
let toggleRecording        = staticLetString("toggleRecording",        in: source) ?? "⌥Space"
let pushToTalk             = staticLetString("pushToTalk",             in: source) ?? "(unbound)"
let rewriteWithVoice       = staticLetString("rewriteWithVoice",       in: source) ?? "(unbound)"
let rewrite                = staticLetString("rewrite",                in: source) ?? "(unbound)"
let pasteLast              = staticLetString("pasteLast",              in: source) ?? "(unbound)"

// Provider costs
let costs = parseProviderCosts(in: source)

// Model info from ParakeetModelID metadata — keep in sync here; the prose
// references the downloaded model size.
let modelName = "Parakeet TDT 0.6B v3"
let modelSize = "~600 MB"  // Approximate user-facing number; the internal
                           // `approxBytes` ~1.25 GB counts decompressed CoreML
                           // bundles on disk. The download size the user sees
                           // is closer to 600 MB (compressed).

// MARK: - Emit

try? FileManager.default.createDirectory(at: fragmentsDir, withIntermediateDirectories: true)

func write(_ name: String, _ content: String) {
    let url = fragmentsDir.appendingPathComponent("\(name).md")
    // Normalize trailing newline.
    let body = content.hasSuffix("\n") ? content : content + "\n"
    try? body.write(to: url, atomically: true, encoding: .utf8)
}

let langList = languages.joined(separator: ", ")
write("languages",
      "\(languages.count) European languages (\(langList))")

// Jot's installable ASR models, one per supported transcription language.
let jotASRBullets = jotASRLanguages.map { "- \($0)" }.joined(separator: "\n")
write("jot-asr-languages", jotASRBullets)

write("cleanup-passes",
      cleanupPasses.joined(separator: "; "))

write("articulate-invariants",
      invariants.joined(separator: "; "))

write("articulate-branches",
      branches.joined(separator: " / "))

let retentionList = retention.joined(separator: ", ")
write("retention",
      "options: \(retentionList)")

write("model-info",
      "\(modelName), \(modelSize)")

// Cost stanza — one provider per bullet so the prose reads naturally.
let costLines = costs.map { "- \($0.provider): \($0.cost)" }.joined(separator: "\n")
write("costs", costLines)

// Default shortcuts — one bullet per binding.
let shortcutLines = [
    "- Toggle recording: \(toggleRecording)",
    "- Push-to-talk: \(pushToTalk)",
    "- Rewrite with Voice: \(rewriteWithVoice)",
    "- Rewrite: \(rewrite)",
    "- Paste last: \(pasteLast)",
].joined(separator: "\n")
write("default-shortcuts", shortcutLines)

// Individual defaults used inline in the base prose.
write("default-shortcuts-toggle", toggleRecording)
write("default-shortcuts-rewrite-with-voice", rewriteWithVoice)
write("default-shortcuts-rewrite", rewrite)
write("default-shortcuts-paste-last", pasteLast)

let emittedCount = 11
print("generate-fragments: wrote \(emittedCount) fragments to \(fragmentsDir.path)")
