import Combine
import Foundation

/// MainActor-isolated singleton owning the `@Published` streaming
/// partial transcript that the recording pill reads.
///
/// Why a singleton: partials are emitted from the live-preview engine
/// (`PreviewScheduler` or `NemotronStreamingTranscriber`, an actor that
/// lives inside `DualPipelineTranscriber`), need to
/// reach `PillViewModel` (a MainActor `ObservableObject`), and apply
/// uniformly to every voice-capture site (Dictation, Articulate
/// voice-instruction, Ask Jot voice input). A shared store with
/// session bracketing keeps the pill subscriber and the streaming
/// engine from inventing parallel session-id spaces — the pipeline's
/// own `Token.generation` is the only authority.
///
/// Lifecycle (per §4.3, §8.5 of the streaming-option plan):
/// 1. `VoiceInputPipeline.startRecording` mints a `Token` with a
///    monotonically-increasing `generation` and immediately calls
///    `beginSession(token:)`.
/// 2. The streaming engine's `onPartial` callback funnels each new
///    transcript snapshot through `publish(_:token:)`.
/// 3. `endSession()` runs from `stopAndTranscribe` / `cancel`. It
///    clears `partial` to `nil`, which triggers the pill to drop
///    back to its non-streaming compact width.
///
/// Stale-token gate: `publish(_:token:)` ignores callbacks whose
/// generation doesn't match the current session. Without the gate, a
/// late callback from a just-finished engine could overwrite a fresh
/// session's partial with stale text.
@MainActor
final class StreamingPartialStore: ObservableObject {

    static let shared = StreamingPartialStore()

    /// `nil` while no streaming session is active or before the first
    /// non-empty partial. The pill subscriber treats `nil` and `""` the
    /// same way — both fall back to the compact pill — so the
    /// distinction is purely operational (debugging the lifecycle).
    @Published private(set) var partial: String?

    /// `true` while a streaming session is active (regardless of
    /// whether any partial text has been emitted yet). Used by
    /// `PillViewModel` / `OverlayWindowController` to decide whether
    /// the pill is tappable for tap-to-expand. Non-streaming primaries
    /// (v3 / JA) leave this `false` so their pills stay click-through.
    @Published private(set) var isActive: Bool = false

    /// Active session generation. `nil` between sessions. `publish`
    /// rejects callbacks whose token doesn't match.
    private var activeGeneration: UInt64?

    private init() {}

    /// Begin a new streaming session. Resets `partial` to `nil` so the
    /// pill subscriber clears any stale text from a prior session
    /// before the engine has a chance to emit its first partial.
    func beginSession(token: UInt64) {
        activeGeneration = token
        partial = nil
        isActive = true
    }

    /// Publish a streaming partial for `token`. Stale callbacks (whose
    /// generation doesn't match `activeGeneration`) are dropped on the
    /// floor — they're benign, just out-of-date.
    func publish(_ text: String, token: UInt64) {
        guard activeGeneration == token else { return }
        // Treat empty / whitespace-only emissions as `nil` so the pill
        // doesn't render a streaming-wide frame containing nothing.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = trimmed.isEmpty ? nil : text
        // Identity dedup before publishing — `@Published` would emit
        // the change anyway, but downstream Combine subscribers get a
        // pre-equality dedup as cheap insurance.
        if next != partial {
            partial = next
        }
    }

    /// End the current session. Clears `partial` so the pill drops
    /// back to compact. Idempotent — repeated calls or calls outside
    /// any session are no-ops.
    func endSession() {
        activeGeneration = nil
        if partial != nil {
            partial = nil
        }
        if isActive {
            isActive = false
        }
    }
}
