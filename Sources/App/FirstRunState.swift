import SwiftUI
import Combine

@MainActor
final class FirstRunState: ObservableObject {
    static let shared = FirstRunState()

    @AppStorage("jot.setupComplete") var setupComplete: Bool = false

    var isFirstLaunch: Bool { !setupComplete }

    func markComplete() {
        // Wizard auto-flip rule (Advanced mode design.md §migration):
        // completing the wizard introduces Custom Vocabulary, AI features,
        // and Prompts — hiding them post-walkthrough would be a UX
        // contradiction. Write both keys directly to UserDefaults so any
        // `@AppStorage` binding observes the change immediately. The
        // `setupComplete = true` assignment below keeps this property's
        // `@AppStorage` wrapper in sync.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "jot.setupComplete")
        defaults.set(true, forKey: AdvancedFlag.storageKey)
        setupComplete = true
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: "jot.setupComplete")
        objectWillChange.send()
    }
}
