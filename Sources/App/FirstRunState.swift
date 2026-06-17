import SwiftUI
import Combine

@MainActor
final class FirstRunState: ObservableObject {
    static let shared = FirstRunState()

    @AppStorage("jot.setupComplete") var setupComplete: Bool = false

    var isFirstLaunch: Bool { !setupComplete }

    func markComplete() {
        // New installs default to Advanced OFF (slim mode) and STAY off
        // after the wizard. We deliberately do NOT touch
        // `AdvancedFlag.storageKey` here — completing the wizard no longer
        // auto-flips Advanced ON. Users opt in via Settings → General.
        //
        // This is distinct from the grandfather/upgrade migration in
        // `AdvancedFlag.migrateIfNeeded()`, which seeds Advanced ON for
        // EXISTING users upgrading from a pre-advanced-flag version (they
        // already have `jot.setupComplete == true` at first launch). That
        // migration is preserved; only this new-install wizard flip is gone.
        //
        // Write `jot.setupComplete` directly to UserDefaults so any
        // `@AppStorage` binding observes the change immediately. The
        // `setupComplete = true` assignment below keeps this property's
        // `@AppStorage` wrapper in sync.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "jot.setupComplete")
        setupComplete = true
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: "jot.setupComplete")
        objectWillChange.send()
    }
}
