import Combine
import Foundation

/// Bridges `RecorderController` state transitions and `lastResult` emissions
/// into `SoundPlayer` calls. Owned by `AppDelegate` for the app lifetime.
///
/// State-transition mapping:
///   `.idle → .recording`            → `recordingStart`
///   `.recording → .idle`            → `recordingCancel` (user aborted; no
///                                     transcription ran)
///   `.recording → .transcribing`    → `recordingStop`
///   `anything → .error(_)`          → `error`
///
/// The `transcriptionComplete` chime rides on `$lastResult` — that publisher
/// fires exactly once per successful transcription, which is what we want.
/// Playing it on `.transcribing → .idle` would also double-fire alongside
/// `lastResult` and a user-facing "error → idle" recovery.
///
/// The initial `.idle` value Combine replays on `.sink` is intentionally
/// swallowed (see `previousState`) so the app doesn't chirp on launch.
@MainActor
final class SoundTriggers {
    private let player: SoundPlayer
    private var previousState: RecorderController.State = .idle
    private var previousRewriteState: RewriteController.RewriteState = .idle
    private var cancellables: Set<AnyCancellable> = []

    convenience init() {
        self.init(player: .shared)
    }

    init(player: SoundPlayer) {
        self.player = player
    }

    func start(recorder: RecorderController) {
        recorder.$state
            .sink { [weak self] next in
                self?.handleTransition(to: next)
            }
            .store(in: &cancellables)

        recorder.$lastResult
            .compactMap { $0 }
            .sink { [weak self] _ in
                self?.player.play(.transcriptionComplete)
            }
            .store(in: &cancellables)
    }

    /// Subscribe the rewrite controller's state machine into the same
    /// chime vocabulary. Rewrite with Voice mirrors the dictation flow:
    /// `.recording` fires `recordingStart`, `recording → transcribing`
    /// fires `recordingStop`, `.rewriting → .idle` is treated as the
    /// paste-back "done" moment and fires `transcriptionComplete`.
    /// Rewrite (fixed) skips the `.recording` step, so it gets the
    /// `rewriteStart` chime on capturing → rewriting instead — every
    /// rewrite announces its start, not just the voice one.
    func start(rewrite: RewriteController) {
        rewrite.$state
            .sink { [weak self] next in
                self?.handleRewriteTransition(to: next)
            }
            .store(in: &cancellables)
    }

    private func handleTransition(to next: RecorderController.State) {
        defer { previousState = next }

        switch (previousState, next) {
        case (.idle, .recording), (.error, .recording):
            player.play(.recordingStart)

        case (.recording, .idle):
            // User hit cancel: the transcribing path would have routed through
            // `.transcribing` first.
            player.play(.recordingCancel)

        case (.recording, .transcribing):
            player.play(.recordingStop)

        case (_, .error):
            player.play(.error)

        default:
            break
        }
    }

    private func handleRewriteTransition(
        to next: RewriteController.RewriteState
    ) {
        defer { previousRewriteState = next }

        switch (previousRewriteState, next) {
        case (_, .recording):
            // Entering the mic-live phase from capturing (or error recovery).
            // Uses a dedicated chime (pitch-shifted from recordingStart) so
            // Rewrite with Voice is audibly distinguishable from dictation.
            player.play(.rewriteStart)

        case (.capturing, .rewriting), (.idle, .rewriting):
            // No voice step (fixed Rewrite, or a prompt picked without
            // speaking): the rewrite itself is the start. After a voice step
            // the chime already played on `.recording`, so it isn't repeated.
            player.play(.rewriteStart)

        case (.recording, .transcribing):
            player.play(.recordingStop)

        case (.recording, .idle):
            // User aborted before transcription kicked in.
            player.play(.recordingCancel)

        case (.rewriting, .idle):
            // LLM finished and paste-back succeeded — the Rewrite
            // analogue of dictation's `lastResult` emission.
            player.play(.transcriptionComplete)

        case (_, .error):
            player.play(.error)

        default:
            break
        }
    }
}
