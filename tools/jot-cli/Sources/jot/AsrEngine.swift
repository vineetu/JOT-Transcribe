import CoreML
import FluidAudio
import Foundation

enum AsrEngineError: Error, CustomStringConvertible {
    case modelMissing(URL)
    case transcribeFailed(Error)

    var description: String {
        switch self {
        case .modelMissing(let dir):
            return """
                Parakeet model not found at \(dir.path).
                Open Jot once to download the transcription model, then retry \
                (or pass --model-dir pointing at a directory containing a \
                parakeet-tdt-0.6b-v3-coreml bundle).
                """
        case .transcribeFailed(let error):
            return "transcription failed: \(error)"
        }
    }
}

/// Loads Parakeet TDT v3 via FluidAudio's batch `AsrManager` — the same
/// engine + loader `tools/nemotron-probe` proves runs headless via SPM, and
/// the same model the app defaults new installs to
/// (`Transcriber.init(modelID: .tdt_0_6b_v3)`). `tokenTimings` on the
/// returned `ASRResult` is what drives the "with timings" WebVTT path
/// (design doc §8 R1 / §6).
///
/// Deviation from the design doc's "Parakeet TDT / Nemotron" framing: v1
/// only wires Parakeet v3. Nemotron loads through a separate streaming
/// manager (`StreamingNemotronAsrManager`) with a `process`/`finish` API
/// shape instead of a single `transcribe(_:)` call, and never returns
/// per-word timings — adding it would double the engine-wiring surface for
/// a model that produces the strictly less useful (uncued) VTT output. The
/// no-timings single-cue fallback path is still implemented and exercised
/// (see WebVTT.swift's `vtt(fullTranscript:durationSeconds:)` and the
/// standalone formatter check in the verification report) — it's just not
/// reachable from a real Nemotron run in this v1.
enum AsrEngine {
    struct Result {
        let text: String
        let duration: TimeInterval
        let tokenTimings: [TokenTiming]?
    }

    /// Cheap disk-presence check, exposed so `main` can fail on missing
    /// models BEFORE paying for the ffmpeg decode — a fresh install piping an
    /// hour-long video should hear "open Jot first" immediately, not after a
    /// full decode.
    static func modelsPresent(modelRoot: URL) -> Bool {
        AsrModels.modelsExist(
            at: ModelPaths.parakeetV3BundleDir(root: modelRoot),
            version: .v3, encoderPrecision: .int8)
    }

    static func transcribe(
        samples: [Float], modelRoot: URL, language: Language? = nil
    ) async throws -> Result {
        let bundleDir = ModelPaths.parakeetV3BundleDir(root: modelRoot)
        guard AsrModels.modelsExist(at: bundleDir, version: .v3, encoderPrecision: .int8) else {
            throw AsrEngineError.modelMissing(bundleDir)
        }

        let models: AsrModels
        do {
            models = try await AsrModels.load(from: bundleDir, version: .v3, encoderPrecision: .int8)
        } catch {
            throw AsrEngineError.transcribeFailed(error)
        }

        let manager = AsrManager()
        do {
            try await manager.loadModels(models)
        } catch {
            throw AsrEngineError.transcribeFailed(error)
        }

        var decoderState = TdtDecoderState.make(decoderLayers: AsrModelVersion.v3.decoderLayers)
        do {
            let result = try await manager.transcribe(samples, decoderState: &decoderState, language: language)
            return Result(text: result.text, duration: TimeInterval(result.duration), tokenTimings: result.tokenTimings)
        } catch {
            throw AsrEngineError.transcribeFailed(error)
        }
    }
}
