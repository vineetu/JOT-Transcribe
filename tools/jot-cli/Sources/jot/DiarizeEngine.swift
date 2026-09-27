import CoreML
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
            return "diarizer model not found at \(path) — run `\(programName) setup --components diarizer` "
                + "(or tap \"Detect speakers\" once in Jot) to download it (~190 MB), then retry"
        }
    }
}

/// NVIDIA Nemotron 3 Diarization (FluidAudio `Nemotron3Diarizer`, `fast128`
/// — the same preset and on-disk copy as the app's `DiarizerHolder`). Runs
/// AFTER transcription finishes, never concurrently (FluidAudio #661: two
/// CoreML graphs must not run at once — the app's `CoreMLInferenceGate`
/// rationale).
///
/// Loads strictly offline (design A3): no `loadFromHuggingFace` — its
/// stale-cache purge could delete the app's copy — and no
/// `load(config:directory:)`, which expects `learnable_sil_emb.bin` next to
/// the bundle when it actually sits at the repo root, one level above
/// `monolithic/v2/`. The bundle and the silence embedding are read by hand
/// and handed to the public `Nemotron3Models` init.
enum DiarizeEngine {
    static let config: Nemotron3Config = .fast128

    /// `<root>/nemotron-3-diarization/` — where both the app and
    /// `setup --components diarizer` put the model.
    static func repoDirectory(root: URL) -> URL {
        root.appendingPathComponent(Repo.nemotron3Diarization.folderName, isDirectory: true)
    }

    static func bundleURL(root: URL) -> URL {
        repoDirectory(root: root)
            .appendingPathComponent(config.hubSubdirectory, isDirectory: true)
            .appendingPathComponent(config.modelFileName, isDirectory: true)
    }

    /// Mirrors `DiarizerHolder.modelsPresent`: the compiled bundle's
    /// manifest, the root silence embedding, and a weights marker whose
    /// CONTENT matches this FluidAudio build (a cache from an older
    /// checkpoint is not "ready" — setup would replace it).
    static func modelsPresent(root: URL) -> Bool {
        let repo = repoDirectory(root: root)
        let fm = FileManager.default
        let manifest = bundleURL(root: root).appendingPathComponent("coremldata.bin")
        let silence = repo.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile)
        let marker = repo.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile)
        guard fm.fileExists(atPath: manifest.path), fm.fileExists(atPath: silence.path) else { return false }
        let cached = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cached == ModelNames.Nemotron3.weightsVersion
    }

    /// Diarize 16 kHz mono samples into exclusive speech runs
    /// (`DiarizationProjection.project`, shared with the app).
    static func diarize(samples: [Float], modelRoot: URL) throws -> [DiarSegment] {
        guard modelsPresent(root: modelRoot) else {
            throw DiarizeEngineError.modelsMissing(repoDirectory(root: modelRoot).path)
        }
        do {
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = .all
            let model = try MLModel(contentsOf: bundleURL(root: modelRoot), configuration: mlConfig)

            let silenceURL = repoDirectory(root: modelRoot)
                .appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile)
            let silenceData = try Data(contentsOf: silenceURL)
            guard silenceData.count == config.preEncoderDims * MemoryLayout<Float>.size else {
                throw DiarizeEngineError.modelsMissing(silenceURL.path)
            }
            let silence = silenceData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

            let models = try Nemotron3Models(config: config, model: model, silenceEmbedding: silence)
            let diarizer = Nemotron3Diarizer(config: config, models: models)
            let (probabilities, frameCount) = try diarizer.processComplete(samples)
            return DiarizationProjection.project(
                probabilities: probabilities,
                frameCount: frameCount,
                numSpeakers: config.numSpeakers
            )
        } catch let error as DiarizeEngineError {
            throw error
        } catch {
            throw DiarizeEngineError.diarizeFailed(error)
        }
    }
}
