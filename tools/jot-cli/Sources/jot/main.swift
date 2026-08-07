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

func fail(_ message: String) -> Never {
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

@MainActor func takeFlag(_ name: String) -> Bool {
    let present = args.contains(name)
    args.removeAll { $0 == name }
    return present
}

// MARK: - Stream mode (`jot --stream`, design doc §15)

if takeFlag("--stream") {
    let language = CLILanguage(takeOpt(["--language"]) ?? "en")
    let rate = takeOpt(["--rate"]) ?? "16000"
    guard rate == "16000" else {
        fail("unsupported --rate '\(rate)': only 16000 is supported")
    }
    let encodingRaw = takeOpt(["--encoding"]) ?? "s16le"
    guard let encoding = PCMEncoding(rawValue: encodingRaw) else {
        fail("unsupported --encoding '\(encodingRaw)': use s16le or f32le")
    }
    let noVocab = takeFlag("--no-vocab")
    let vocabPath = takeOpt(["--vocab"])
    let modelDirOverride = takeOpt(["--model-dir"])

    if let stray = args.first {
        fail("unexpected argument '\(stray)' in --stream mode\n\n\(usage)")
    }

    let vocab: VocabularyApplier?
    do {
        vocab = try VocabularyApplier.load(
            explicitPath: vocabPath, disabled: noVocab, language: language)
    } catch {
        fail("\(error)")
    }

    await StreamMode.run(StreamMode.Options(
        language: language,
        encoding: encoding,
        modelDirOverride: modelDirOverride,
        vocab: vocab
    ))
}

// MARK: - Batch mode (`jot transcribe`)

guard args.first == "transcribe" else {
    FileHandle.standardError.write(Data("jot: unknown command '\(args.first ?? "")'\n\n".utf8))
    printUsageAndExit(2)
}
args.removeFirst()

let diarize = takeFlag("--diarize")
let wantVTT = takeFlag("--vtt") || diarize  // --diarize implies WebVTT output
let raw = takeFlag("--raw")
let noVocab = takeFlag("--no-vocab")
let vocabPath = takeOpt(["--vocab"])
let language = CLILanguage(takeOpt(["--language"]) ?? "en")
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

let vocab: VocabularyApplier?
do {
    vocab = try VocabularyApplier.load(
        explicitPath: vocabPath, disabled: noVocab, language: language)
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
