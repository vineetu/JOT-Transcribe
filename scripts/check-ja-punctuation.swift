// check-ja-punctuation.swift
//
// Empirical punctuation check for the Parakeet JA model (Phase 4 release
// blocker — docs/plans/japanese-support.md item 12).
//
// What this script does:
//   1. Loads the Parakeet JA model via FluidAudio's `AsrManager`
//      (`AsrModels.load(from:version:.tdtJa)`). The model must already be
//      downloaded — see docs/plans/japanese-punctuation-check.md for the
//      one-time download flow (driven by Settings → Transcription in the
//      live app once Phase 4 model-registry work has shipped).
//   2. Iterates ja-01.wav through ja-20.wav under
//      Tests/JotHarness/Fixtures/audio/, decodes each to canonical
//      16 kHz mono Float32 (mirrors `JotHarness+Dictate.decodeFile`).
//   3. Calls `manager.transcribe(samples, source: .microphone)` for each.
//   4. Prints a per-fixture table: file, expected sentence, transcript,
//      detected punctuation style.
//   5. Aggregates ASCII vs full-width vs neither and prints a single-line
//      RESULT verdict the team-lead consumes:
//        RESULT: emit-style is full-width
//        RESULT: emit-style is ASCII
//        RESULT: emit-style is mixed
//
// IMPORTANT: this file cannot be run as a standalone `swift script.swift`
// because FluidAudio is not available on the global Swift toolchain
// module path — Jot pulls it in through Xcode's SwiftPackageReference. To
// run, use the SwiftPM mini-package that wraps this file:
//
//   cd scripts/ja-punctuation-check
//   swift run -c release JaPunctuationCheck
//
// The Package.swift in scripts/ja-punctuation-check/ pins FluidAudio to the
// same 0.13.x line Jot ships with and points its sources at this file via
// a relative path. Running it from anywhere else fails fast with a clear
// "FluidAudio not available" error.
//
// The script is intentionally side-effect-free aside from stdout writes:
// no model download, no cache mutation, no network. If the JA model is not
// in the expected on-disk location, it prints download instructions and
// exits non-zero so a CI invocation fails loudly rather than silently.

import FluidAudio
import Foundation
@preconcurrency import AVFoundation

// MARK: - Paths

let repoRoot: URL = {
    // This file lives at <repo>/scripts/check-ja-punctuation.swift. The
    // mini-package compiles it via a relative `path:` so #filePath resolves
    // correctly regardless of where `swift run` is invoked from.
    let here = URL(fileURLWithPath: #filePath)
    return here.deletingLastPathComponent().deletingLastPathComponent()
}()

let fixturesDir = repoRoot
    .appendingPathComponent("Tests/JotHarness/Fixtures/audio", isDirectory: true)

// Mirror Jot's `ModelCache.shared` layout. `ModelCache` lives under
// `~/Library/Application Support/Jot/Models/Parakeet/` and JA's
// repoFolderName is `parakeet-ctc-ja` (per ParakeetModelID.swift).
let modelCacheRoot: URL = {
    let appSupport = try! FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    )
    return appSupport
        .appendingPathComponent("Jot/Models/Parakeet", isDirectory: true)
        .appendingPathComponent("parakeet-ctc-ja", isDirectory: true)
}()

// MARK: - Expected sentences (kept aligned with scripts/gen-ja-samples.sh)

let expected: [String] = [
    "こんにちは。",
    "今日はいい天気ですね。",
    "今何時ですか？",
    "すごい！",
    "私は学生です。",
    "本を読みます。",
    "明日は雨が降るでしょう。",
    "ありがとうございました。",
    "もう一度言ってください。",
    "それは何ですか？",
    "彼は学校に行きました。",
    "猫が好きです。",
    "今、忙しいです。",
    "頑張ってください！",
    "どこに行きますか？",
    "これは美味しいですね。",
    "音楽を聴いています。",
    "ご飯を食べました。",
    "もう寝る時間です。",
    "電車が遅れています。",
]

// MARK: - WAV decode (mirrors Tests/JotHarness/JotHarness+Dictate.decodeFile)

enum DecodeError: Error {
    case bufferAllocationFailed
    case targetFormatUnavailable
    case converterUnavailable
    case conversion(Error)
}

func decodeFile(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let processingFormat = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0 else { return [] }

    guard let inBuffer = AVAudioPCMBuffer(
        pcmFormat: processingFormat,
        frameCapacity: frameCount
    ) else {
        throw DecodeError.bufferAllocationFailed
    }
    try file.read(into: inBuffer)

    if processingFormat.sampleRate == 16_000,
       processingFormat.channelCount == 1,
       processingFormat.commonFormat == .pcmFormatFloat32,
       !processingFormat.isInterleaved {
        return floats(from: inBuffer)
    }

    guard let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ) else {
        throw DecodeError.targetFormatUnavailable
    }
    guard let converter = AVAudioConverter(from: processingFormat, to: target) else {
        throw DecodeError.converterUnavailable
    }
    let ratio = 16_000.0 / processingFormat.sampleRate
    let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1024)
    guard let outBuffer = AVAudioPCMBuffer(
        pcmFormat: target,
        frameCapacity: outCapacity
    ) else {
        throw DecodeError.bufferAllocationFailed
    }

    var supplied = false
    var convertError: NSError?
    let status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
        if supplied {
            inputStatus.pointee = .noDataNow
            return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return inBuffer
    }
    if status == .error, let convertError {
        throw DecodeError.conversion(convertError)
    }
    return floats(from: outBuffer)
}

func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
    guard let data = buffer.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
}

// MARK: - Punctuation classification

let asciiPunct: Set<Character> = [".", ",", "?", "!"]
let fullWidthPunct: Set<Character> = ["。", "、", "？", "！"]

enum PunctType: String {
    case ascii = "ASCII"
    case fullWidth = "full-width"
    case mixed = "mixed"
    case none = "none"
}

func classify(_ text: String) -> PunctType {
    let hasAscii = text.contains(where: { asciiPunct.contains($0) })
    let hasFull = text.contains(where: { fullWidthPunct.contains($0) })
    switch (hasAscii, hasFull) {
    case (true, true): return .mixed
    case (true, false): return .ascii
    case (false, true): return .fullWidth
    case (false, false): return .none
    }
}

// MARK: - Run

@main
struct Main {
    static func main() async {
        // Pre-flight: model must be cached.
        if !FileManager.default.fileExists(atPath: modelCacheRoot.path) {
            fputs("""
            ERROR: Parakeet JA model not found at:
              \(modelCacheRoot.path)

            Download it via the live Jot app:
              1. Build & launch Jot (Phase 4 model-registry must be merged
                 so the multi-install picker is visible).
              2. Open Settings → Transcription.
              3. On the "Parakeet 0.6B Japanese" row, click Download.
              4. Wait for the row to flip to Installed (~1.25 GB; few minutes
                 on a fast connection).
              5. Re-run this script.

            Alternative: trigger a download programmatically via
            ModelDownloader.downloadIfMissing(.tdt_0_6b_ja, ...) from a
            scratch target. Do not download by hand into the cache dir —
            FluidAudio's loader is picky about which files exist.
            \n
            """, stderr)
            exit(2)
        }

        // Pre-flight: fixtures must exist.
        let missing = (1...20).map { idx -> String? in
            let name = String(format: "ja-%02d.wav", idx)
            let url = fixturesDir.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? nil : name
        }.compactMap { $0 }
        if !missing.isEmpty {
            fputs("ERROR: missing fixtures: \(missing.joined(separator: ", "))\n", stderr)
            fputs("Run scripts/gen-ja-samples.sh to regenerate.\n", stderr)
            exit(3)
        }

        do {
            try await runCheck()
        } catch {
            fputs("FATAL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func runCheck() async throws {
        print("Loading Parakeet JA from \(modelCacheRoot.path) ...")
        let models = try await AsrModels.load(
            from: modelCacheRoot,
            version: .tdtJa
        )
        let manager = AsrManager()
        try await manager.loadModels(models)
        print("Model loaded.\n")

        print(String(format: "%-12s %-28s %-32s %s",
                     "FILE", "EXPECTED", "TRANSCRIPT", "PUNCT_TYPE"))
        print(String(repeating: "-", count: 100))

        var asciiCount = 0
        var fullCount = 0
        var noneCount = 0
        var mixedCount = 0

        for idx in 1...20 {
            let name = String(format: "ja-%02d.wav", idx)
            let url = fixturesDir.appendingPathComponent(name)
            let exp = expected[idx - 1]

            let samples: [Float]
            do {
                samples = try decodeFile(url)
            } catch {
                print(String(format: "%-12s %-28s [decode-error: %@] %@",
                             name, exp, "\(error)", PunctType.none.rawValue))
                noneCount += 1
                continue
            }

            // FluidAudio requires ≥ 1 s of audio. The Kyoko fixtures all
            // satisfy this (shortest is ja-01 at ~0.84 s) — but ja-01 may
            // be marginal. Pad with trailing silence if too short, so the
            // model still gets a deterministic shot at the punctuation.
            let padded: [Float] = samples.count >= 16_000
                ? samples
                : samples + Array(repeating: 0, count: 16_000 - samples.count)

            let result: ASRResult
            do {
                result = try await manager.transcribe(padded, source: .microphone)
            } catch {
                print(String(format: "%-12s %-28s [asr-error: %@] %@",
                             name, exp, "\(error)", PunctType.none.rawValue))
                noneCount += 1
                continue
            }

            let transcript = result.text
            let pt = classify(transcript)
            switch pt {
            case .ascii: asciiCount += 1
            case .fullWidth: fullCount += 1
            case .mixed: mixedCount += 1
            case .none: noneCount += 1
            }

            print(String(format: "%-12s %-28s %-32s %@",
                         name, exp, transcript, pt.rawValue))
        }

        print()
        print("ASCII punctuation:      \(asciiCount)/20")
        print("Full-width punctuation: \(fullCount)/20")
        print("Mixed (both):           \(mixedCount)/20")
        print("Neither:                \(noneCount)/20")
        print()

        let verdict: String
        if mixedCount > 0 || (asciiCount > 0 && fullCount > 0) {
            verdict = "mixed"
        } else if asciiCount > fullCount {
            verdict = "ASCII"
        } else if fullCount > asciiCount {
            verdict = "full-width"
        } else {
            verdict = "neither (model emitted no recognized punctuation)"
        }
        print("RESULT: emit-style is \(verdict)")
    }
}
