@preconcurrency import FluidAudio
@preconcurrency import CoreML
import Combine
import Foundation
import os.log

/// Lifecycle owner for the Sortformer streaming diarization model, the
/// sibling of `TranscriberHolder` for Speaker Labels piece A. Why a holder
/// vs. a free-floating `SortformerDiarizer`:
///
/// * Diarization is *togglable* — flipping the master OFF must release the
///   ANE handle without re-running enrollment. The holder is the seam where
///   "loaded vs not" lives, separate from "the diarizer exists in code."
/// * The download path and warmup path need the same lock semantics —
///   re-entering enrollment, dropping the in-memory `_models` reference,
///   re-loading and replaying clips. A class makes that book-keeping
///   localized; consumers (post-stop labeler) just ask `currentDiarizer()`.
/// * Multiple SwiftUI surfaces (Settings → Speaker Labels pane, Settings →
///   Transcription card) need to observe load state. `ObservableObject`
///   does that without re-wiring `@Published` plumbing in each pane.
///
/// Concurrency: `@MainActor` because all observers are SwiftUI surfaces on
/// the main actor. The actual model load + enrollment work runs inside
/// `Task.detached` because CoreML compile + ANE warmup is heavy; the
/// holder hops back to `@MainActor` to swap the published reference.
@MainActor
public final class SortformerHolder: ObservableObject {

    public enum State: Equatable {
        case notSetUp
        case downloading(progress: Double)
        case downloadFailed(message: String)
        case offHaveModel
        case loading
        case loaded
        case unsupportedHardware
    }

    @Published public private(set) var state: State

    private let cache: SortformerModelCache
    private let downloader: SortformerModelDownloader
    private let log = Logger(subsystem: "com.jot.Jot", category: "SortformerHolder")

    /// The underlying diarizer once loaded. `nil` until `loadIfNeeded()`
    /// runs and the model finishes compiling. Consumers that need to
    /// produce a timeline post-stop should call `currentDiarizer()` so the
    /// in-flight-load state is observed and respected.
    private var diarizer: SortformerDiarizer?

    public init(
        cache: SortformerModelCache = .shared,
        downloader: SortformerModelDownloader? = nil,
        hardwareIsSupported: Bool = SortformerHardwareGate.isSupported
    ) {
        self.cache = cache
        self.downloader = downloader ?? SortformerModelDownloader(cache: cache)
        if !hardwareIsSupported {
            self.state = .unsupportedHardware
        } else if cache.isCached {
            self.state = .offHaveModel
        } else {
            self.state = .notSetUp
        }
    }

    /// Download the Sortformer model if it isn't on disk yet. Drives the
    /// `downloading` / `downloadFailed` states. Idempotent — re-entering
    /// while a download is in flight short-circuits.
    public func downloadModelIfNeeded(
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        if case .downloading = state { return }
        guard !cache.isCached else {
            if state == .notSetUp || state == .downloading(progress: 0) || stateIsDownloading {
                state = .offHaveModel
            }
            progressHandler?(1.0)
            return
        }

        state = .downloading(progress: 0)
        SortformerDiag.log("downloadModelIfNeeded START")
        let downloader = self.downloader
        do {
            try await downloader.downloadIfMissing(progress: { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    self.state = .downloading(progress: fraction)
                    progressHandler?(fraction)
                }
            })
            state = .offHaveModel
            SortformerDiag.log("downloadModelIfNeeded SUCCESS state=.offHaveModel cached=\(cache.isCached)")
        } catch {
            log.error("Sortformer download failed: \(String(describing: error), privacy: .public)")
            SortformerDiag.log("downloadModelIfNeeded FAILED error=\(String(describing: error))")
            state = .downloadFailed(message: error.localizedDescription)
            throw error
        }
    }

    /// Compile and load the Sortformer model, then replay the supplied
    /// voice clips through `enrollSpeaker(withAudio:)` so slot↔name
    /// bindings are live for the next recording. No-op when the model is
    /// already loaded.
    ///
    /// - Parameter clips: ordered list of `(name, audioSamples)` pairs.
    ///   Pass an empty array to load the model without any enrollments.
    public func loadIfNeeded(clips: [EnrolledClip]) async {
        SortformerDiag.log("loadIfNeeded ENTRY state=\(state) clips.count=\(clips.count) cached=\(cache.isCached)")
        switch state {
        case .loaded, .loading, .unsupportedHardware, .notSetUp, .downloading, .downloadFailed:
            switch state {
            case .loaded, .loading, .unsupportedHardware:
                SortformerDiag.log("loadIfNeeded EARLY RETURN state=\(state)")
                return
            default:
                break
            }
        default:
            break
        }
        guard cache.isCached else {
            log.warning("loadIfNeeded called without a cached Sortformer bundle")
            SortformerDiag.log("loadIfNeeded ABORT: cache.isCached=false")
            return
        }

        state = .loading
        let bundleURL = cache.bundleURL
        let config = SortformerConfig.fastV2_1
        let logRef = self.log

        // Heavy work — CoreML JIT-compile + ANE warmup + per-clip
        // enrollSpeaker passes — runs on a detached priority-userInitiated
        // task so the toggle in Settings doesn't freeze the UI for 1-3 s.
        // `SortformerDiarizer` and `MLModel` aren't `Sendable`, so the
        // diarizer transfers back to MainActor inside an `@unchecked
        // Sendable` box. Safe in practice: nothing else touches `diar`
        // until we publish it onto `self.diarizer` here on MainActor.
        do {
            let boxed = try await Task.detached(priority: .userInitiated) {
                let mainConfig = MLModelConfiguration()
                mainConfig.computeUnits = .all
                // FluidAudio's `initialize(mainModelPath:)` always runs the
                // model through `MLModel.compileModel(at:)` first. That API
                // expects a `.mlmodel` / `.mlpackage` source — but
                // FluidAudio's downloader ships the already-compiled
                // `.mlmodelc`. On macOS 26 the compile step hard-fails on a
                // `.mlmodelc` input with a misleading "A valid manifest does
                // not exist" CoreML error. Workaround: load the compiled
                // bundle directly via `MLModel(contentsOf:)` and hand the
                // resulting `SortformerModels` to the diarizer via its
                // pre-loaded overload.
                let mainModel = try MLModel(contentsOf: bundleURL, configuration: mainConfig)
                let models = try SortformerModels(config: config, main: mainModel)
                let diar = SortformerDiarizer(config: config, timelineConfig: .sortformerDefault)
                diar.initialize(models: models)

                for clip in clips {
                    do {
                        _ = try diar.enrollSpeaker(
                            withAudio: clip.samples,
                            sourceSampleRate: Double(SortformerConfig.fastV2_1.sampleRate),
                            named: clip.name,
                            overwritingAssignedSpeakerName: true
                        )
                    } catch {
                        logRef.error("Failed to enroll '\(clip.name, privacy: .public)': \(String(describing: error), privacy: .public)")
                    }
                }
                return UncheckedDiarizerBox(diarizer: diar)
            }.value

            diarizer = boxed.diarizer
            state = .loaded
            SortformerDiag.log("loadIfNeeded SUCCESS state=.loaded diarizer set")
        } catch {
            log.error("Sortformer model load failed: \(String(describing: error), privacy: .public)")
            SortformerDiag.log("loadIfNeeded FAILED error=\(String(describing: error))")
            diarizer = nil
            state = .offHaveModel
        }
    }

    /// Box that lets us transfer a non-`Sendable` `SortformerDiarizer`
    /// back from the off-actor load task to MainActor. Safe in practice:
    /// the diarizer is constructed inside the detached task, returned
    /// once, and only ever read/mutated on MainActor afterwards (no
    /// concurrent access).
    private struct UncheckedDiarizerBox: @unchecked Sendable {
        let diarizer: SortformerDiarizer
    }

    /// Drop the in-memory model. ARC reclaims the ANE handle; on-disk
    /// bundle is preserved so a future `loadIfNeeded` is instant.
    public func unload() {
        diarizer?.cleanup()
        diarizer = nil
        if cache.isCached {
            state = .offHaveModel
        } else {
            state = .notSetUp
        }
    }

    /// Hand the current diarizer to a caller (post-stop labeling). Returns
    /// nil if the model isn't loaded — caller must decide whether to skip
    /// labels or wait. Speaker Labels piece A's post-stop labeler treats a
    /// nil return as "no timeline for this recording."
    public func currentDiarizer() -> SortformerDiarizer? {
        return diarizer
    }

    /// Enroll a single new identity into the already-loaded diarizer. No-op
    /// (returns false) when the model isn't loaded — caller should save the
    /// clip to SwiftData and wait for the next `loadIfNeeded` to pick it up.
    @discardableResult
    public func enrollLiveIfLoaded(clip: EnrolledClip) -> Bool {
        guard let diar = diarizer else { return false }
        do {
            _ = try diar.enrollSpeaker(
                withAudio: clip.samples,
                sourceSampleRate: Double(SortformerConfig.fastV2_1.sampleRate),
                named: clip.name,
                overwritingAssignedSpeakerName: true
            )
            return true
        } catch {
            log.error("Live enrollment failed for '\(clip.name, privacy: .public)': \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private var stateIsDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }
}

/// A single voice clip to enroll into Sortformer at warmup time. Maps 1:1
/// to an `EnrolledIdentity` row's first `voiceClips` entry decoded as
/// `[Float]`.
public struct EnrolledClip: Sendable {
    public let name: String
    public let samples: [Float]

    public init(name: String, samples: [Float]) {
        self.name = name
        self.samples = samples
    }
}

/// Hardware gate per plan Decision #1: Speaker Labels' two ANE pipelines
/// (Parakeet + Sortformer) need at least 16 GB of physical RAM.
public enum SortformerHardwareGate {
    public static var isSupported: Bool {
        ProcessInfo.processInfo.physicalMemory >= UInt64(16) * 1_073_741_824
    }
}
