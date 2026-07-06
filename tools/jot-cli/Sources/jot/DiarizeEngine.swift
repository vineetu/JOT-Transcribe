import FluidAudio
import Foundation

enum DiarizeEngineError: Error, CustomStringConvertible {
    case diarizeFailed(Error)
    case modelsMissing(String)

    var description: String {
        switch self {
        case .diarizeFailed(let error):
            return "diarization failed: \(error)"
        case .modelsMissing(let path):
            return "diarizer models not found at \(path) — open Jot once and run "
                + "\"Detect speakers\" on any recording to download them, then retry"
        }
    }
}

/// Loads FluidAudio's offline VBx diarizer (`OfflineDiarizerManager`) exactly
/// like `tools/diarize-probe`, and runs it AFTER transcription finishes —
/// never concurrently (design doc §2 / the app's `CoreMLInferenceGate`
/// rationale: FluidAudio #661, two CoreML graphs must not run at once).
enum DiarizeEngine {
    static func diarize(samples: [Float], modelRoot: URL) async throws -> DiarizationResult {
        // Pre-check: don't let `prepareModels` reach for the network (design §5 —
        // the CLI never downloads; the app owns model lifecycle). If the diarizer
        // model dir is absent/empty, fail with a clear message. Review R2.
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: modelRoot.path)) ?? []
        guard fm.fileExists(atPath: modelRoot.path), !contents.isEmpty else {
            throw DiarizeEngineError.modelsMissing(modelRoot.path)
        }
        let manager = OfflineDiarizerManager(config: .default)
        do {
            try await manager.prepareModels(directory: modelRoot)
            return try await manager.process(audio: samples)
        } catch {
            throw DiarizeEngineError.diarizeFailed(error)
        }
    }
}
