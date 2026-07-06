import FluidAudio
import Foundation

let version = "0.1.0"

let usage = """
    jot — transcribe an audio/video file to WebVTT, with optional speaker diarization.

    USAGE:
      jot transcribe <file> [--diarize] [-o <out.vtt>] [--model-dir <dir>]
      jot --help
      jot --version

    OPTIONS:
      --diarize            Run offline speaker diarization and label cues
                            <v Speaker N>. Diarization is only reliable on
                            clean, separate-audio-per-voice input (e.g. a
                            Zoom/Meet recording's own soundtrack) — not audio
                            captured acoustically through speakers into a mic.
      -o, --output <path>  Write WebVTT to <path> instead of stdout.
      --model-dir <dir>    Override the Parakeet model directory (defaults to
                            ~/Library/Application Support/Jot/Models/Parakeet,
                            the same directory Jot.app downloads into).
      -h, --help           Show this help.
      --version            Show the version.
    """

@MainActor func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("jot: error: \(message)\n".utf8))
    exit(1)
}

@MainActor func printUsageAndExit(_ code: Int32) -> Never {
    if code == 0 {
        print(usage)
    } else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args.contains("--help") || args.contains("-h") {
    printUsageAndExit(0)
}
if args.contains("--version") {
    print("jot \(version)")
    exit(0)
}

guard args[0] == "transcribe" else {
    FileHandle.standardError.write(Data("jot: unknown command '\(args[0])'\n\n".utf8))
    printUsageAndExit(2)
}
args.removeFirst()

@MainActor func takeOpt(_ names: [String]) -> String? {
    for name in names {
        if let i = args.firstIndex(of: name), i + 1 < args.count {
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
    }
    return nil
}

let diarize = args.contains("--diarize")
args.removeAll { $0 == "--diarize" }
let outputPath = takeOpt(["-o", "--output"])
let modelDirOverride = takeOpt(["--model-dir"])

// Reject any leftover unrecognized option: a typo like `--diariz` must NOT be
// silently dropped (which would yield a non-diarized transcript with exit 0).
// Review C2.
if let stray = args.first(where: { $0.hasPrefix("-") }) {
    fail("unknown option '\(stray)'\n\n\(usage)")
}
guard let inputPath = args.first else {
    fail("missing <file> argument\n\n\(usage)")
}
guard args.count == 1 else {
    fail("unexpected extra argument(s): \(args.dropFirst().joined(separator: " "))\n\n\(usage)")
}
guard FileManager.default.fileExists(atPath: inputPath) else {
    fail("input file not found: \(inputPath)")
}

let parakeetRoot = ModelPaths.parakeetRoot(override: modelDirOverride)
let diarizerRoot = ModelPaths.diarizerRoot

// MARK: - Pipeline

@MainActor func run() async {
    let samples: [Float]
    do {
        samples = try FFmpegDecoder.decodeToMono16k(inputPath)
    } catch {
        fail("decode failed: \(error)")
    }
    guard !samples.isEmpty else {
        fail("decoded audio is empty (no audio track in \(inputPath)?)")
    }

    let asr: AsrEngine.Result
    do {
        asr = try await AsrEngine.transcribe(samples: samples, modelRoot: parakeetRoot)
    } catch {
        fail("\(error)")
    }

    let vtt: String
    if diarize {
        vtt = await buildDiarizedVTT(samples: samples, asr: asr)
    } else {
        vtt = buildPlainVTT(asr: asr)
    }

    if let outputPath {
        do {
            try vtt.write(toFile: outputPath, atomically: true, encoding: .utf8)
        } catch {
            fail("failed to write \(outputPath): \(error)")
        }
    } else {
        print(vtt)
    }
}

@MainActor func buildPlainVTT(asr: AsrEngine.Result) -> String {
    if let tokenTimings = asr.tokenTimings, !tokenTimings.isEmpty {
        let words = WordReassembly.words(from: tokenTimings)
        let cues = CueBuilder.cues(fromWords: words)
        if !cues.isEmpty {
            return WebVTT.vtt(timedCues: cues)
        }
    }
    // Nemotron path (no tokenTimings) or a degenerate empty-cues case:
    // single cue spanning the whole clip (design doc §6).
    return WebVTT.vtt(fullTranscript: asr.text, durationSeconds: asr.duration)
}

@MainActor func buildDiarizedVTT(samples: [Float], asr: AsrEngine.Result) async -> String {
    let diarization: DiarizationResult
    do {
        diarization = try await DiarizeEngine.diarize(samples: samples, modelRoot: diarizerRoot)
    } catch {
        FileHandle.standardError.write(
            Data("jot: warning: diarization failed (\(error)) — falling back to plain transcript\n".utf8))
        return buildPlainVTT(asr: asr)
    }

    let rawSegments = diarization.segments.map {
        (speakerId: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
    }
    let merged = CueBuilder.mergeAdjacent(rawSegments)
    guard !merged.isEmpty else {
        FileHandle.standardError.write(
            Data("jot: note: no distinct speaker segments detected (single speaker, or audio not clean per-voice) — falling back to plain transcript\n".utf8))
        return buildPlainVTT(asr: asr)
    }

    let labels = CueBuilder.labels(for: merged)
    let diarizedSegments: [(speaker: String, start: Double, end: Double, text: String)]
    if let tokenTimings = asr.tokenTimings, !tokenTimings.isEmpty {
        let words = WordReassembly.words(from: tokenTimings)
        diarizedSegments = CueBuilder.diarizedSegments(words: words, segments: merged, labels: labels)
    } else {
        diarizedSegments = CueBuilder.distributeText(transcript: asr.text, segments: merged, labels: labels)
    }
    return WebVTT.vtt(diarizedSegments: diarizedSegments)
}

await run()
