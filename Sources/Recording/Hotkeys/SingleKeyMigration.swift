import Foundation
import KeyboardShortcuts

/// One-shot migration on the first launch of the build that introduced
/// `SingleKey` bindings for `.toggleRecording`. Gated by an
/// `@AppStorage`-style boolean so it runs exactly once per install.
///
/// Policy:
///   • **Fresh install** (`FirstRunState.setupComplete == false`) →
///     default to `SingleKey.capsLock` and clear the chord binding so
///     the user's only out-of-the-box hotkey is Caps Lock. The Setup
///     Wizard's Test step shows Caps Lock and walks them through
///     pressing it.
///   • **Existing user** (`setupComplete == true`) → leave their chord
///     binding alone (whether they were on the `⌥Space` default or
///     customized to anything else) and start `SingleKey` at `.none`.
///     They're not surprised; they keep what they had. Caps Lock is
///     opt-in from Settings → Shortcuts.
///
/// We use raw `UserDefaults` reads here rather than `@AppStorage` so the
/// migration can run from `AppDelegate.applicationDidFinishLaunching`
/// before any SwiftUI view has materialized.
@MainActor
enum SingleKeyMigration {
    private static let migratedKey = "jot.hotkey.toggleRecording.migrated"
    static let singleOrChordCompletedKey = "jot.hotkey.singleOrChordMigration.completed"
    private static let keyboardShortcutsDefaultsPrefix = "KeyboardShortcuts_"

    struct AmbiguousAction: Identifiable, Equatable {
        var id: SingleKey.Action { action }
        let action: SingleKey.Action
        let singleKey: SingleKey
        let chordDescription: String
    }

    struct EffectiveBinding: Equatable {
        let action: SingleKey.Action
        let triggerType: SingleKey.TriggerType
        let singleKey: SingleKey
        let chordDescription: String?

        var label: String? {
            switch triggerType {
            case .singleKey:
                return singleKey == .none ? nil : singleKey.displayName
            case .chord:
                return chordDescription
            }
        }

        var displayLabel: String {
            label ?? "(not set)"
        }
    }

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)

        if FirstRunState.shared.setupComplete {
            // Existing user — leave chord, single-key starts at None.
            // No-op; the @AppStorage default of `.none` is correct.
        } else {
            // Fresh install — Caps Lock is the new default toggle.
            defaults.set(SingleKey.capsLock.rawValue, forKey: SingleKey.storageKey)
            // Clears the library's `⌥Space` default so Caps Lock is the
            // only out-of-the-box Toggle Recording trigger.
            setTriggerType(.singleKey, for: .toggleRecording)
            // Fresh installs are already born into the single-or-chord model.
            markSingleOrChordMigrationCompleted()
        }
    }

    static func shouldPresentSingleOrChordWizard(
        wasSetupCompleteAtLaunch: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        wasSetupCompleteAtLaunch
            && !defaults.bool(forKey: singleOrChordCompletedKey)
    }

    static func markSingleOrChordMigrationCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: singleOrChordCompletedKey)
    }

    static func ambiguousActions(defaults: UserDefaults = .standard) -> [AmbiguousAction] {
        SingleKey.Action.allCases.compactMap { action in
            ambiguousAction(for: action, defaults: defaults)
        }
    }

    static func ambiguousAction(
        for action: SingleKey.Action,
        defaults: UserDefaults = .standard
    ) -> AmbiguousAction? {
        guard storedTriggerType(for: action, defaults: defaults) == nil else { return nil }
        let singleKey = storedSingleKey(for: action, defaults: defaults)
        guard singleKey != .none else { return nil }
        guard rawChordIsActive(for: action, defaults: defaults) else { return nil }
        return AmbiguousAction(
            action: action,
            singleKey: singleKey,
            chordDescription: rawChordDescription(for: action, defaults: defaults) ?? "Chord"
        )
    }

    static func effectiveTriggerType(
        for action: SingleKey.Action,
        defaults: UserDefaults = .standard
    ) -> SingleKey.TriggerType {
        if let stored = storedTriggerType(for: action, defaults: defaults) {
            return stored
        }

        let singleKey = storedSingleKey(for: action, defaults: defaults)
        let chordActive = rawChordIsActive(for: action, defaults: defaults)

        if singleKey != .none && !chordActive {
            return .singleKey
        }
        if chordActive {
            return .chord
        }
        return action.defaultTriggerType
    }

    static func effectiveBinding(
        for action: SingleKey.Action,
        defaults: UserDefaults = .standard
    ) -> EffectiveBinding {
        let triggerType = effectiveTriggerType(for: action, defaults: defaults)
        let singleKey = storedSingleKey(for: action, defaults: defaults)
        let chordDescription: String?

        switch triggerType {
        case .singleKey:
            chordDescription = nil
        case .chord:
            chordDescription = KeyboardShortcuts.getShortcut(for: action.keyboardShortcutsName)?.description
        }

        return EffectiveBinding(
            action: action,
            triggerType: triggerType,
            singleKey: singleKey,
            chordDescription: chordDescription
        )
    }

    static func effectiveBindingLabel(for action: SingleKey.Action) -> String? {
        effectiveBinding(for: action).label
    }

    static func setTriggerType(_ type: SingleKey.TriggerType, for action: SingleKey.Action) {
        let defaults = UserDefaults.standard
        defaults.set(type.rawValue, forKey: action.triggerTypeStorageKey)

        switch type {
        case .singleKey:
            KeyboardShortcuts.setShortcut(nil, for: action.keyboardShortcutsName)
        case .chord:
            defaults.set(SingleKey.none.rawValue, forKey: action.storageKey)
        }
    }

    static func storedTriggerType(
        for action: SingleKey.Action,
        defaults: UserDefaults = .standard
    ) -> SingleKey.TriggerType? {
        guard let raw = defaults.string(forKey: action.triggerTypeStorageKey) else { return nil }
        return SingleKey.TriggerType(rawValue: raw)
    }

    static func storedSingleKey(
        for action: SingleKey.Action,
        defaults: UserDefaults = .standard
    ) -> SingleKey {
        let raw = defaults.string(forKey: action.storageKey) ?? SingleKey.none.rawValue
        return SingleKey(rawValue: raw) ?? .none
    }

    static func rawChordIsActive(
        for action: SingleKey.Action,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = rawKeyboardShortcutsDefaultsKey(for: action)
        guard let stored = defaults.object(forKey: key) else {
            return action.hasDeclaredChordDefault
        }
        if let disabled = stored as? Bool {
            return disabled != false
        }
        if let encoded = stored as? String {
            return !encoded.isEmpty
        }
        return false
    }

    static func rawChordDescription(
        for action: SingleKey.Action,
        defaults: UserDefaults = .standard
    ) -> String? {
        let key = rawKeyboardShortcutsDefaultsKey(for: action)
        guard let stored = defaults.object(forKey: key) else {
            return action.defaultChordDescription
        }
        if let disabled = stored as? Bool, disabled == false {
            return nil
        }
        guard let encoded = stored as? String,
              let data = encoded.data(using: .utf8),
              let shortcut = try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data)
        else {
            return nil
        }
        return shortcut.description
    }

    static func rawKeyboardShortcutsDefaultsKey(for action: SingleKey.Action) -> String {
        "\(keyboardShortcutsDefaultsPrefix)\(action.rawKeyboardShortcutsName)"
    }
}
