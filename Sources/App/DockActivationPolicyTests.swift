#if DEBUG
import AppKit
import Foundation

/// DEBUG-only runtime tests for the "Show Jot in the Dock" gate
/// function (`dockActivationPolicy(setupComplete:storedShowInDock:)`)
/// defined in `AppDelegate.swift`.
///
/// Mirrors the `HelpInfraTests` pattern: no XCTest dependency, the
/// suite is called once from `AppDelegate.applicationDidFinishLaunching`
/// in DEBUG so misses fire at launch. Tests the pure function — no
/// AppKit chrome, no UserDefaults round-trip.
enum DockActivationPolicyTests {
    static func runAll() {
        test_setupIncomplete_forcesRegular_evenWhenStoredFalse()
        test_setupIncomplete_isRegular_whenStoredIsNil()
        test_setupIncomplete_isRegular_whenStoredTrue()
        test_setupComplete_storedNil_defaultsToRegular()
        test_setupComplete_storedTrue_isRegular()
        test_setupComplete_storedFalse_isAccessory()
    }

    /// Setup-Wizard guard: while `setupComplete == false`, the function
    /// must return `.regular` regardless of the stored toggle so the
    /// wizard window always has a Dock icon during permission grants.
    static func test_setupIncomplete_forcesRegular_evenWhenStoredFalse() {
        let policy = dockActivationPolicy(
            setupComplete: false,
            storedShowInDock: false
        )
        assert(
            policy == .regular,
            "Setup wizard pending must force .regular even when stored=false; got \(policy)"
        )
    }

    static func test_setupIncomplete_isRegular_whenStoredIsNil() {
        let policy = dockActivationPolicy(
            setupComplete: false,
            storedShowInDock: nil
        )
        assert(
            policy == .regular,
            "Setup wizard pending must force .regular when no stored value; got \(policy)"
        )
    }

    static func test_setupIncomplete_isRegular_whenStoredTrue() {
        let policy = dockActivationPolicy(
            setupComplete: false,
            storedShowInDock: true
        )
        assert(
            policy == .regular,
            "Setup wizard pending + stored=true should be .regular; got \(policy)"
        )
    }

    /// Default for a fresh install once setup completes: no value
    /// written yet → default to showing in Dock (.regular) so existing
    /// users' behavior is preserved by the migration story.
    static func test_setupComplete_storedNil_defaultsToRegular() {
        let policy = dockActivationPolicy(
            setupComplete: true,
            storedShowInDock: nil
        )
        assert(
            policy == .regular,
            "No stored value should default to .regular (Dock visible); got \(policy)"
        )
    }

    static func test_setupComplete_storedTrue_isRegular() {
        let policy = dockActivationPolicy(
            setupComplete: true,
            storedShowInDock: true
        )
        assert(
            policy == .regular,
            "stored=true should produce .regular; got \(policy)"
        )
    }

    /// The opt-out case: setup is complete AND the user explicitly
    /// turned the toggle off. Only this combination yields `.accessory`.
    static func test_setupComplete_storedFalse_isAccessory() {
        let policy = dockActivationPolicy(
            setupComplete: true,
            storedShowInDock: false
        )
        assert(
            policy == .accessory,
            "setup complete + stored=false should produce .accessory; got \(policy)"
        )
    }
}
#endif
