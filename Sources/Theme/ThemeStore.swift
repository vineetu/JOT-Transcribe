import Combine
import SwiftUI

/// Observable holder for the selected `JotTheme`.
///
/// SwiftUI needs a published change to re-render, but the pill and the sound
/// player live outside the SwiftUI environment (they're AppKit-hosted), so they
/// read `JotTheme.current` off `UserDefaults` directly. This type keeps the two
/// worlds in step: it writes the same key those readers use, and broadcasts so
/// the SwiftUI tree re-renders.
///
/// A singleton rather than an injected dependency because the AppKit surfaces
/// have no environment to inject into — see `JotAppWindow`'s note about
/// `AppServices.live` lazy reaches for why we don't reach for that pattern here:
/// this holds no services and has no launch-ordering dependency, it is a single
/// `UserDefaults`-backed value.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    /// Posted after `theme` changes so AppKit-hosted surfaces (the overlay pill)
    /// can refresh — they cannot observe an `ObservableObject`.
    static let didChangeNotification = Notification.Name("jot.appearance.themeDidChange")

    @Published private(set) var theme: JotTheme

    private init() {
        theme = JotTheme.current
    }

    func select(_ newValue: JotTheme) {
        guard newValue != theme else { return }
        UserDefaults.standard.set(newValue.rawValue, forKey: JotTheme.storageKey)
        // Invalidate BEFORE publishing: `theme = ...` triggers observers to
        // re-render synchronously, and they read `JotTheme.current`.
        JotTheme.invalidateCache()
        theme = newValue
        // Cached players hold decoded audio for the previous theme's files.
        SoundPlayer.shared.themeDidChange()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Re-read from defaults. Used after a reset wipes the domain, so the
    /// in-memory value doesn't drift from what's stored.
    func reload() {
        JotTheme.invalidateCache()
        let stored = JotTheme.current
        guard stored != theme else { return }
        theme = stored
        SoundPlayer.shared.themeDidChange()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
