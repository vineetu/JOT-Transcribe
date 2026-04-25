#!/usr/bin/env swift

// concat-help-content.swift
//
// Build Phase 2 of the grounding-doc pipeline (spec v5 §11).
//
// Reads `Resources/help-content-base.md`, replaces every
// `<!-- FRAGMENT: name -->` placeholder with the contents of
// `Resources/fragments/name.md`, and writes the concatenated result to
// `Resources/help-content.md`.
//
// Fails with a clear error on:
//   * missing base file,
//   * an unmatched placeholder (fragment file not present),
//   * an unused fragment (sanity check — a fragment with no placeholder
//     is almost always a typo; logged as a warning, not a failure).

import Foundation

let repoRoot: URL = {
    if let srcroot = ProcessInfo.processInfo.environment["SRCROOT"] {
        return URL(fileURLWithPath: srcroot)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}()

let baseFile = repoRoot
    .appendingPathComponent("Resources")
    .appendingPathComponent("help-content-base.md")

let fragmentsDir = repoRoot
    .appendingPathComponent("Resources")
    .appendingPathComponent("fragments")

let outFile = repoRoot
    .appendingPathComponent("Resources")
    .appendingPathComponent("help-content.md")

guard let base = try? String(contentsOf: baseFile, encoding: .utf8) else {
    FileHandle.standardError.write("concat-help-content: cannot read \(baseFile.path)\n".data(using: .utf8)!)
    exit(1)
}

// Extract `<!-- FRAGMENT: name -->` placeholders.
let pattern = #"<!--\s*FRAGMENT:\s*([a-zA-Z0-9_-]+)\s*-->"#
guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
    FileHandle.standardError.write("concat-help-content: regex compile failed\n".data(using: .utf8)!)
    exit(1)
}

let ns = base as NSString
let matches = regex.matches(in: base, range: NSRange(location: 0, length: ns.length))

var referenced = Set<String>()
for m in matches where m.numberOfRanges > 1 {
    referenced.insert(ns.substring(with: m.range(at: 1)))
}

// Verify each referenced fragment exists.
for name in referenced.sorted() {
    let frag = fragmentsDir.appendingPathComponent("\(name).md")
    guard FileManager.default.fileExists(atPath: frag.path) else {
        FileHandle.standardError.write(
            "concat-help-content: ERROR — placeholder <!-- FRAGMENT: \(name) --> has no matching Resources/fragments/\(name).md\n".data(using: .utf8)!
        )
        exit(1)
    }
}

// Warn on unused fragments on disk (but don't fail the build).
if let onDisk = try? FileManager.default.contentsOfDirectory(atPath: fragmentsDir.path) {
    let emitted = Set(
        onDisk
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
    )
    for orphan in emitted.subtracting(referenced).sorted() {
        FileHandle.standardError.write(
            "concat-help-content: warning — fragment '\(orphan)' has no placeholder in help-content-base.md\n".data(using: .utf8)!
        )
    }
}

// Perform the substitution. Go back-to-front so earlier ranges stay valid.
var out = base
let reversedMatches = matches.reversed()
for m in reversedMatches where m.numberOfRanges > 1 {
    let name = ns.substring(with: m.range(at: 1))
    let fragURL = fragmentsDir.appendingPathComponent("\(name).md")
    guard let raw = try? String(contentsOf: fragURL, encoding: .utf8) else {
        FileHandle.standardError.write("concat-help-content: cannot read \(fragURL.path)\n".data(using: .utf8)!)
        exit(1)
    }
    // Trim trailing newlines — inline splices shouldn't double-line-break.
    let fragment = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let nsOut = out as NSString
    let fullRange = m.range(at: 0)
    out = nsOut.replacingCharacters(in: fullRange, with: fragment)
}

try? out.write(to: outFile, atomically: true, encoding: .utf8)
print("concat-help-content: wrote \(outFile.path) (\(out.count) chars, \(referenced.count) placeholders filled)")
