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
    private var cancellables: Set<AnyCancellable> = []

    init(player: SoundPlayer = .shared) {
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
}
