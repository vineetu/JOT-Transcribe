import Foundation
import Testing
@testable import Jot

@MainActor
@Suite(.serialized)
struct SingleKeyMigrationTests {
    private static func freshDefaults() -> (String, UserDefaults) {
        let name = "jot.tests.single-key-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (name, defaults)
    }

    private static let jsonShortcut = #"{"carbonKeyCode":49,"carbonModifiers":2048}"#

    @Test func absentPushToTalkDefaultIsNotChordActive() {
        let (suite, defaults) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SingleKey.rightOption.rawValue, forKey: SingleKey.Action.pushToTalk.storageKey)

        #expect(SingleKeyMigration.rawChordIsActive(for: .pushToTalk, defaults: defaults) == false)
        #expect(SingleKeyMigration.ambiguousAction(for: .pushToTalk, defaults: defaults) == nil)
    }

    @Test func explicitBoolFalseDisablesDeclaredDefault() {
        let (suite, defaults) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SingleKey.capsLock.rawValue, forKey: SingleKey.Action.toggleRecording.storageKey)
        defaults.set(
            false,
            forKey: SingleKeyMigration.rawKeyboardShortcutsDefaultsKey(for: .toggleRecording)
        )

        #expect(SingleKeyMigration.rawChordIsActive(for: .toggleRecording, defaults: defaults) == false)
        #expect(SingleKeyMigration.ambiguousAction(for: .toggleRecording, defaults: defaults) == nil)
    }

    @Test func jsonStringMarksChordActive() throws {
        let (suite, defaults) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SingleKey.fn.rawValue, forKey: SingleKey.Action.pushToTalk.storageKey)
        defaults.set(
            Self.jsonShortcut,
            forKey: SingleKeyMigration.rawKeyboardShortcutsDefaultsKey(for: .pushToTalk)
        )

        let ambiguity = try #require(SingleKeyMigration.ambiguousAction(for: .pushToTalk, defaults: defaults))
        #expect(ambiguity.action == .pushToTalk)
        #expect(ambiguity.singleKey == .fn)
    }

    @Test func singleOnlyBindingDerivesSingleKeyTrigger() {
        let (suite, defaults) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SingleKey.rightCommand.rawValue, forKey: SingleKey.Action.rewrite.storageKey)
        defaults.set(
            false,
            forKey: SingleKeyMigration.rawKeyboardShortcutsDefaultsKey(for: .rewrite)
        )

        #expect(SingleKeyMigration.ambiguousAction(for: .rewrite, defaults: defaults) == nil)
        #expect(SingleKeyMigration.effectiveTriggerType(for: .rewrite, defaults: defaults) == .singleKey)
    }

    @Test func bothBoundDeclaredDefaultIsAmbiguous() throws {
        let (suite, defaults) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SingleKey.capsLock.rawValue, forKey: SingleKey.Action.toggleRecording.storageKey)

        let ambiguity = try #require(SingleKeyMigration.ambiguousAction(for: .toggleRecording, defaults: defaults))
        #expect(ambiguity.action == .toggleRecording)
        #expect(ambiguity.singleKey == .capsLock)
        #expect(ambiguity.chordDescription == "⌥Space")
    }

    @Test func existingTriggerTypeSuppressesAmbiguity() {
        let (suite, defaults) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SingleKey.capsLock.rawValue, forKey: SingleKey.Action.toggleRecording.storageKey)
        defaults.set(
            SingleKey.TriggerType.singleKey.rawValue,
            forKey: SingleKey.Action.toggleRecording.triggerTypeStorageKey
        )

        #expect(SingleKeyMigration.ambiguousAction(for: .toggleRecording, defaults: defaults) == nil)
    }

}
