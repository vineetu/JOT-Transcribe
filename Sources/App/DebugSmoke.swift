#if DEBUG
import Foundation
import os.log

/// Manual end-to-end smoke path for Phase 2: record 3 seconds, transcribe,
/// print the result. Not wired to any launch trigger — callable from the T9
/// smoke screen or from an `await DebugSmoke.recordAndTranscribe3s()` in
/// `AppDelegate` during ad-hoc testing.
///
/// Requires microphone permission and a fully cached Parakeet model. Both
/// conditions are pre-checked; failures print diagnostic messages rather
/// than throwing, since the intended consumer is a human at the keyboard.
@MainActor
enum DebugSmoke {
    private static let log = Logger(subsystem: "com.jot.Jot", category: "DebugSmoke")

    static func recordAndTranscribe3s() async {
        let permissions = PermissionsService.shared
        permissions.refreshAll()

        guard permissions.statuses[.microphone] == .granted else {
            print("[DebugSmoke] microphone not granted — current status: \(String(describing: permissions.statuses[.microphone]))")
            return
        }

        let cache = ModelCache.shared
        let modelID = ParakeetModelID.tdt_0_6b_v3
        guard cache.isCached(modelID) else {
            print("[DebugSmoke] Parakeet model not cached — run the model downloader first")
            return
        }

        let capture = AudioCapture()
        let transcriber = Transcriber(cache: cache, modelID: modelID)

        do {
            print("[DebugSmoke] loading model…")
            try await transcriber.ensureLoaded()

            print("[DebugSmoke] recording 3 seconds…")
            try await capture.start()
            try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            let recording = try await capture.stop()

            print("[DebugSmoke] captured \(recording.samples.count) samples (\(String(format: "%.2f", recording.duration))s) → \(recording.fileURL.path)")

            print("[DebugSmoke] transcribing…")
            let result = try await transcriber.transcribe(recording.samples)
            print("[DebugSmoke] transcript: \(result.text)")
            print("[DebugSmoke] raw: \(result.rawText)")
            print("[DebugSmoke] duration: \(result.duration)s processingTime: \(result.processingTime)s confidence: \(result.confidence)")
        } catch {
            print("[DebugSmoke] failed: \(String(describing: error))")
        }
    }
}
#endif
