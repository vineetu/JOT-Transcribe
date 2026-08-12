import CoreML
import FluidAudio
import Foundation

/// `jot batch` — noise-robustness bench harness (not shipped; a dev tool).
///
/// Transcribes a manifest of audio files with the model loaded ONCE, so a
/// few hundred clips run in minutes instead of re-loading Parakeet per file.
/// Emits JSONL: {"path": "...", "text": "..."} per line.
///
/// Flags:
///   --manifest <file>        newline-separated list of audio paths (required)
///   --model-version v2|v3    which Parakeet checkpoint (default v3)
///   --vad                    gate out non-speech with Silero VAD before ASR
///                            (tests "skip the silence" — kills noise-only
///                            segments that make the decoder hallucinate)
///   --model-dir <dir>        override Parakeet root
///   -o, --output <path>      write JSONL here instead of stdout
@MainActor
func runBatch(_ rawArgs: [String]) async {
    var args = rawArgs

    func takeOpt(_ names: [String]) -> String? {
        for name in names {
            if let i = args.firstIndex(of: name), i + 1 < args.count {
                let v = args[i + 1]
                args.removeSubrange(i...(i + 1))
                return v
            }
        }
        return nil
    }

    let manifestPath = takeOpt(["--manifest", "-m"])
    let outputPath = takeOpt(["-o", "--output"])
    let modelDirOverride = takeOpt(["--model-dir"])
    let versionStr = takeOpt(["--model-version"]) ?? "v3"
    let useVad = args.contains("--vad")
    args.removeAll { $0 == "--vad" }

    if let stray = args.first(where: { $0.hasPrefix("-") }) {
        fail("batch: unknown option '\(stray)'")
    }
    guard let manifestPath else { fail("batch: --manifest <file> required") }
    guard versionStr == "v2" || versionStr == "v3" else {
        fail("batch: --model-version must be v2 or v3 (got '\(versionStr)')")
    }

    guard let manifestText = try? String(contentsOfFile: manifestPath, encoding: .utf8) else {
        fail("batch: cannot read manifest \(manifestPath)")
    }
    let paths = manifestText
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !paths.isEmpty else { fail("batch: manifest is empty") }

    let version: AsrModelVersion = (versionStr == "v2") ? .v2 : .v3
    let root = ModelPaths.parakeetRoot(override: modelDirOverride)
    // Only the parent (the Parakeet root) matters to AsrModels.load — it
    // derives the real folder name (parakeet-tdt-0.6b-<v>) from version.repo.
    let bundleDir = root.appendingPathComponent("parakeet-tdt-0.6b-\(versionStr)-coreml", isDirectory: true)

    FileHandle.standardError.write(Data("batch: loading \(versionStr) models…\n".utf8))
    let models: AsrModels
    do {
        models = try await AsrModels.load(from: bundleDir, version: version, encoderPrecision: .int8)
    } catch {
        fail("batch: model load failed: \(error)")
    }
    let manager = AsrManager()
    do {
        try await manager.loadModels(models)
    } catch {
        fail("batch: manager load failed: \(error)")
    }

    var vad: VadManager?
    if useVad {
        FileHandle.standardError.write(Data("batch: loading Silero VAD…\n".utf8))
        do {
            vad = try await VadManager()
        } catch {
            fail("batch: VAD load failed: \(error)")
        }
    }

    FileHandle.standardError.write(Data("batch: transcribing \(paths.count) files…\n".utf8))
    var out = ""
    for (i, path) in paths.enumerated() {
        var text = ""
        do {
            var samples = try FFmpegDecoder.decodeToMono16k(path)
            if let vad {
                let speechChunks = try await vad.segmentSpeechAudio(samples)
                samples = speechChunks.flatMap { $0 }
            }
            if !samples.isEmpty {
                var decoderState = TdtDecoderState.make(decoderLayers: version.decoderLayers)
                let result = try await manager.transcribe(samples, decoderState: &decoderState, language: nil)
                text = result.text
            }
        } catch {
            FileHandle.standardError.write(Data("\nbatch: \(path): \(error)\n".utf8))
        }
        let obj: [String: String] = ["path": path, "text": text]
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let line = String(data: data, encoding: .utf8) {
            out += line + "\n"
        }
        if (i + 1) % 10 == 0 {
            FileHandle.standardError.write(Data("  \(i + 1)/\(paths.count)\n".utf8))
        }
    }

    if let outputPath {
        do {
            try out.write(toFile: outputPath, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("batch: wrote \(outputPath)\n".utf8))
        } catch {
            fail("batch: failed to write \(outputPath): \(error)")
        }
    } else {
        print(out)
    }
}
