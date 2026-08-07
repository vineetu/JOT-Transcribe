import FluidAudio
import Foundation
import JotTextPipeline

let version = "0.2.0"

let usage = """
    jot — on-device transcription utility (batch files and live streaming).

    USAGE:
      jot transcribe <file> [options]     Transcribe an audio/video file.
      jot --stream [options]              Stream raw PCM from stdin, emit NDJSON finals.
      jot --help | --version

    TRANSCRIBE OPTIONS (default output: cleaned plain text on stdout):
      --vtt                Emit WebVTT cues instead of plain text (v1 behavior).
      --diarize            Speaker-labeled WebVTT cues (implies --vtt).
                            Reliable only on clean, separate-audio-per-voice
                            input (e.g. a Zoom/Meet recording's own soundtrack).
      --raw                Skip the cleanup chain (paragraphs, fillers, number
                            normalization, whitespace). Vocabulary still applies.
      --language <code>    Transcription language hint + cleanup gating
                            (default: en). English-only cleanup stages are
                            skipped for other languages.
      -o, --output <path>  Write to <path> instead of stdout.
      --model-dir <dir>    Override the Parakeet model root (defaults to
                            ~/Library/Application Support/Jot/Models/Parakeet,
                            the same directory Jot.app downloads into).
      --                   End of options (for input files starting with "-").

    STREAM OPTIONS (in: 16 kHz mono PCM on stdin; out: one JSON object per line):
      --language <code>    One language per stream, fixed at startup (default: en).
      --rate <hz>          Input sample rate. Only 16000 is supported.
      --encoding <enc>     s16le (default) or f32le. A leading WAV header is
                            detected and skipped; --encoding governs decoding.
      --model-dir <dir>    As above.

    VOCABULARY (both modes):
      --no-vocab           Disable custom-vocabulary correction.
      --vocab <file>       Use <file> instead of the default
                            ~/Library/Application Support/Jot/Vocabulary/vocabulary.txt.

    EXIT STATUS: 0 success, 1 runtime failure (decode, models, engine), 2 usage.
    Models are downloaded by Jot.app — open Jot once to complete setup.
    See jot-cli(1) for stdin recipes (ffmpeg) and the NDJSON contract.
    """

/// Runtime failure — exit 1. Nonisolated so StreamMode can call it off the
/// main actor; touches no top-level state.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("jot: error: \(message)\n".utf8))
    exit(1)
}

/// Usage error — exit 2, per the documented contract. Scripted callers
/// distinguish "my invocation is wrong" (2) from "engine/models failed" (1).
@MainActor func usageFail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("jot: error: \(message)\n\n\(usage)\n".utf8))
    exit(2)
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

// Mode/help/version detection must not look past a `--` end-of-options
// marker, or `jot transcribe -- -h` would print usage with exit 0 instead of
// transcribing the file named "-h" (review finding). Everything after `--`
// is positional data, owned by parseArgs.
let preDashDash = args.prefix(while: { $0 != "--" })

if args.isEmpty || preDashDash.contains("--help") || preDashDash.contains("-h") {
    printUsageAndExit(args.isEmpty ? 2 : 0)
}
if preDashDash.contains("--version") {
    print("jot \(version)")
    exit(0)
}

// MARK: - Argument parsing

/// Single left-to-right pass (review finding: the old scan-and-remove parser
/// let a missing option value silently swallow the next token — e.g.
/// `--language --raw a.wav b.wav` transcribed the wrong file with exit 0).
/// Rules: an option's value must exist and must not begin with "-";
/// unknown "-" tokens are usage errors; `--` ends option parsing.
struct ParsedArgs {
    var flags: Set<String> = []
    var options: [String: String] = [:]
    var positionals: [String] = []
}

@MainActor func parseArgs(
    _ tokens: [String], flagNames: Set<String>, optionAliases: [String: String]
) -> ParsedArgs {
    var parsed = ParsedArgs()
    var positionalOnly = false
    var i = 0
    while i < tokens.count {
        let tok = tokens[i]
        if positionalOnly {
            parsed.positionals.append(tok)
        } else if tok == "--" {
            positionalOnly = true
        } else if flagNames.contains(tok) {
            parsed.flags.insert(tok)
        } else if let canonical = optionAliases[tok] {
            guard i + 1 < tokens.count, !tokens[i + 1].hasPrefix("-") else {
                usageFail("missing value for \(tok)")
            }
            parsed.options[canonical] = tokens[i + 1]
            i += 1
        } else if tok.hasPrefix("-") {
            usageFail("unknown option '\(tok)'")
        } else {
            parsed.positionals.append(tok)
        }
        i += 1
    }
    return parsed
}

// MARK: - Stream mode (`jot --stream`, design doc §15)

if preDashDash.contains("--stream") {
    // Strip only pre-`--` occurrences; a post-`--` "--stream" is positional.
    let boundary = preDashDash.count
    args = args.enumerated()
        .filter { !($0.element == "--stream" && $0.offset < boundary) }
        .map(\.element)
    let parsed = parseArgs(
        args,
        flagNames: ["--no-vocab"],
        optionAliases: [
            "--language": "--language", "--rate": "--rate", "--encoding": "--encoding",
            "--vocab": "--vocab", "--model-dir": "--model-dir",
        ])
    if let stray = parsed.positionals.first {
        usageFail("unexpected argument '\(stray)' in --stream mode")
    }

    let language = CLILanguage(parsed.options["--language"] ?? "en")
    let rate = parsed.options["--rate"] ?? "16000"
    guard rate == "16000" else {
        usageFail("unsupported --rate '\(rate)': only 16000 is supported")
    }
    let encodingRaw = parsed.options["--encoding"] ?? "s16le"
    guard let encoding = PCMEncoding(rawValue: encodingRaw) else {
        usageFail("unsupported --encoding '\(encodingRaw)': use s16le or f32le")
    }

    let vocab: VocabularyApplier?
    do {
        vocab = try VocabularyApplier.load(
            explicitPath: parsed.options["--vocab"],
            disabled: parsed.flags.contains("--no-vocab"),
            language: language)
    } catch {
        fail("\(error)")
    }

    await StreamMode.run(StreamMode.Options(
        language: language,
        encoding: encoding,
        modelDirOverride: parsed.options["--model-dir"],
        vocab: vocab
    ))
}

// MARK: - Batch mode (`jot transcribe`)

guard args.first == "transcribe" else {
    usageFail("unknown command '\(args.first ?? "")'")
}
args.removeFirst()

let parsed = parseArgs(
    args,
    flagNames: ["--vtt", "--diarize", "--raw", "--no-vocab"],
    optionAliases: [
        "--vocab": "--vocab", "--language": "--language",
        "-o": "-o", "--output": "-o", "--model-dir": "--model-dir",
    ])

let diarize = parsed.flags.contains("--diarize")
let wantVTT = parsed.flags.contains("--vtt") || diarize  // --diarize implies WebVTT
let raw = parsed.flags.contains("--raw")
let language = CLILanguage(parsed.options["--language"] ?? "en")
let outputPath = parsed.options["-o"]
let modelDirOverride = parsed.options["--model-dir"]

guard let inputPath = parsed.positionals.first else {
    usageFail("missing <file> argument")
}
guard parsed.positionals.count == 1 else {
    usageFail("unexpected extra argument(s): \(parsed.positionals.dropFirst().joined(separator: " "))")
}
guard FileManager.default.fileExists(atPath: inputPath) else {
    fail("input file not found: \(inputPath)")
}

let parakeetRoot = ModelPaths.parakeetRoot(override: modelDirOverride)
let diarizerRoot = ModelPaths.diarizerRoot

let vocab: VocabularyApplier?
do {
    vocab = try VocabularyApplier.load(
        explicitPath: parsed.options["--vocab"],
        disabled: parsed.flags.contains("--no-vocab"),
        language: language)
} catch {
    fail("\(error)")
}

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
        asr = try await AsrEngine.transcribe(
            samples: samples, modelRoot: parakeetRoot, language: language.batchHint)
    } catch {
        fail("\(error)")
    }

    let output: String
    if wantVTT {
        if diarize {
            output = await buildDiarizedVTT(samples: samples, asr: asr)
        } else {
            output = buildPlainVTT(asr: asr)
        }
    } else {
        // Default: cleaned plain text (design doc §10). Vocabulary first (on
        // the raw engine text, like the app's rescore-before-segment order),
        // then the deterministic chain unless --raw.
        var text = asr.text
        if let vocab {
            text = vocab.correct(text)
        }
        if !raw {
            let timings = asr.tokenTimings?.map {
                JotTextPipeline.TokenTiming(
                    token: $0.token, startTime: $0.startTime, endTime: $0.endTime)
            }
            text = TranscriptCleanup.apply(text, tokenTimings: timings, language: language)
        }
        output = text
    }

    if let outputPath {
        do {
            try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
        } catch {
            fail("failed to write \(outputPath): \(error)")
        }
    } else {
        print(output)
    }
}

/// Vocabulary correction applied per cue: word-for-word swaps are timing-safe
/// (design §10 — VTT mode never runs the cleanup chain, which would desync
/// cue boundaries, but vocab corrections do apply).
@MainActor func correctCue(_ text: String) -> String {
    vocab?.correct(text) ?? text
}

@MainActor func buildPlainVTT(asr: AsrEngine.Result) -> String {
    if let tokenTimings = asr.tokenTimings, !tokenTimings.isEmpty {
        let words = WordReassembly.words(from: tokenTimings)
        let cues = CueBuilder.cues(fromWords: words)
        if !cues.isEmpty {
            return WebVTT.vtt(timedCues: cues.map { ($0.start, $0.end, correctCue($0.text)) })
        }
    }
    // Nemotron path (no tokenTimings) or a degenerate empty-cues case:
    // single cue spanning the whole clip (design doc §6).
    return WebVTT.vtt(fullTranscript: correctCue(asr.text), durationSeconds: asr.duration)
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
    return WebVTT.vtt(diarizedSegments: diarizedSegments.map {
        ($0.speaker, $0.start, $0.end, correctCue($0.text))
    })
}

await run()
