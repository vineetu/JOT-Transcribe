import AVFoundation
import Foundation
import os.log

/// Plays Jot's bundled chimes via `AVAudioPlayer`. One lazily-instantiated
/// player per effect so overlapping plays don't cut each other off — handy
/// when `recordingStop` and `transcriptionComplete` land within ~200 ms of
/// each other.
///
/// Reads the per-effect `@AppStorage` toggle and `jot.sound.volume` off
/// `UserDefaults.standard` on each play so the most recent Settings value
/// always wins. No caching — the cost of a dictionary read is dwarfed by the
/// audio dispatch.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private let log = Logger(subsystem: "com.jot.Jot", category: "SoundPlayer")
    private var players: [SoundEffect: AVAudioPlayer] = [:]

    /// Default volume when `jot.sound.volume` has never been written.
    /// Matches the default Settings renders in its slider.
    private static let defaultVolume: Float = 0.7

    private init() {}

    /// Warm every player so the first `play(_:)` call has no load latency.
    /// Safe to call multiple times.
    func prewarm() {
        for effect in SoundEffect.allCases {
            _ = player(for: effect)
        }
    }

    func play(_ effect: SoundEffect) {
        let defaults = UserDefaults.standard

        // Toggle default is `true` (keyed values missing → enabled).
        if defaults.object(forKey: effect.settingsKey) != nil,
           defaults.bool(forKey: effect.settingsKey) == false {
            return
        }

        guard let player = player(for: effect) else { return }

        let volume: Float
        if defaults.object(forKey: "jot.sound.volume") != nil {
            volume = Float(defaults.double(forKey: "jot.sound.volume"))
        } else {
            volume = Self.defaultVolume
        }
        player.volume = max(0, min(1, volume))

        if player.isPlaying {
            player.currentTime = 0
        }
        player.play()
    }

    /// Drop cached players after a theme switch — each holds decoded audio for
    /// the *previous* theme's file, so without this the old chimes keep playing
    /// until relaunch. Re-warms so the next play has no load latency.
    func themeDidChange() {
        players.removeAll()
        prewarm()
    }

    private func player(for effect: SoundEffect) -> AVAudioPlayer? {
        if let existing = players[effect] { return existing }
        guard let url = Self.soundURL(for: effect) else {
            log.error("Missing bundled sound: \(effect.fileName, privacy: .public)")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            players[effect] = player
            return player
        } catch {
            log.error("AVAudioPlayer init failed for \(effect.fileName, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Resolve the audio file for `effect` under the current theme.
    ///
    /// Falls back to the stock chime whenever the themed file is absent, so a
    /// missing or half-installed theme asset degrades to today's sound rather
    /// than to silence. Themed files are `.mp3`; the stock set is `.wav`.
    private static func soundURL(for effect: SoundEffect) -> URL? {
        let theme = JotTheme.current
        if theme.soundPrefix != nil {
            let themed = effect.fileName(for: theme)
            if let url = Bundle.main.url(forResource: themed, withExtension: "mp3") { return url }
            if let url = Bundle.main.url(forResource: themed, withExtension: "wav") { return url }
        }
        return Bundle.main.url(forResource: effect.fileName, withExtension: "wav")
    }
}
