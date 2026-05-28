import AppKit
import Foundation
import KeyboardShortcuts
import SwiftUI

@MainActor
enum ResetActions {
    private static var pendingHardResetMarkerURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(".com.jot.Jot.pendingHardReset")
    }

    /// Phase 4 patch round 3: `keychain` seam threaded so per-provider
    /// API key deletion routes through `KeychainStoring` (production:
    /// `LiveKeychain`; harness: `StubKeychain`) instead of the static
    /// `KeychainHelper`. Closes the Phase 3 #29 Scope-A deferral.
    ///
    /// `preserveModelChoice` (streaming-option v2.0 §11 R15): the soft
    /// reset wipes every UserDefaults key including
    /// `jot.defaultModelID` and `jot.modelChoice.v2DefaultStamped`,
    /// which would cause the next launch's classifier to silently
    /// reclassify a streaming user back to v3 when the v3 cache is
    /// missing. Default `true` preserves the model choice so the
    /// user keeps their primary across a soft reset; `hardReset`
    /// passes `false` because the full wipe is intentional.
    static func softReset(keychain: any KeychainStoring, preserveModelChoice: Bool = true) {
        if let bundleID = Bundle.main.bundleIdentifier {
            let preservedModelID: String? = preserveModelChoice
                ? UserDefaults.standard.string(forKey: TranscriberHolder.defaultsKey)
                : nil
            let preservedV2Stamped: Bool = preserveModelChoice
                && UserDefaults.standard.bool(forKey: ModelChoiceMigration.v2DefaultStampedKey)
            let preservedPinChecked: Bool = preserveModelChoice
                && UserDefaults.standard.bool(forKey: ModelChoiceMigration.pinCheckedKey)
            let preservedFourOptionMigrated: Bool = preserveModelChoice
                && UserDefaults.standard.bool(forKey: ModelChoiceMigration.fourOptionMigratedKey)
            let preservedFourOptionDownloadPending: Bool = preserveModelChoice
                && UserDefaults.standard.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey)
            let preservedEouRenameMigrated: Bool = preserveModelChoice
                && UserDefaults.standard.bool(forKey: ModelChoiceMigration.eouRenameMigratedKey)
            // Decision #7: soft reset preserves the sidebar Settings group
            // expand/collapse state (it's a UI presentation preference, not
            // a configurable setting). Hard reset clears it via the
            // `preserveModelChoice == false` path so a `from-scratch`
            // wipe is total. The key is only captured when there's an
            // explicit user-written value — leaving it absent for first-time
            // users so the default-expanded behavior holds.
            let hadSettingsExpandedKey: Bool = preserveModelChoice
                && UserDefaults.standard.object(forKey: "jot.sidebar.settingsExpanded") != nil
            let preservedSettingsExpanded: Bool = hadSettingsExpandedKey
                && UserDefaults.standard.bool(forKey: "jot.sidebar.settingsExpanded")

            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            // Relaunch captures setupComplete=false, so single-or-chord migration stays gated off.

            if preserveModelChoice {
                if let id = preservedModelID {
                    UserDefaults.standard.set(id, forKey: TranscriberHolder.defaultsKey)
                }
                if preservedV2Stamped {
                    UserDefaults.standard.set(true, forKey: ModelChoiceMigration.v2DefaultStampedKey)
                }
                if preservedPinChecked {
                    UserDefaults.standard.set(true, forKey: ModelChoiceMigration.pinCheckedKey)
                }
                if preservedFourOptionMigrated {
                    UserDefaults.standard.set(true, forKey: ModelChoiceMigration.fourOptionMigratedKey)
                }
                if preservedFourOptionDownloadPending {
                    UserDefaults.standard.set(true, forKey: ModelChoiceMigration.fourOptionDownloadPendingKey)
                }
                if preservedEouRenameMigrated {
                    UserDefaults.standard.set(true, forKey: ModelChoiceMigration.eouRenameMigratedKey)
                }
                if hadSettingsExpandedKey {
                    UserDefaults.standard.set(preservedSettingsExpanded, forKey: "jot.sidebar.settingsExpanded")
                }
            }
        }

        clearAPIKeys(keychain: keychain)
        FirstRunState.shared.reset()

        KeyboardShortcuts.reset(
            .toggleRecording,
            .pasteLastTranscription,
            .rewrite,
            .rewriteWithVoice,
            .pushToTalk
        )

        RestartHelper.relaunch()
    }

    static func hardReset(keychain: any KeychainStoring) {
        // Marker FILE (not UserDefaults) survives softReset's
        // removePersistentDomain call. processPendingHardReset on
        // next launch checks for this file and runs the wipe.
        do {
            try Data().write(to: pendingHardResetMarkerURL)
        } catch {
            Task { await ErrorLog.shared.error(component: "ResetActions", message: "hardReset failed to write marker file", context: ["error": ErrorLog.redactedAppleError(error)]) }
        }
        // Hard reset cascades with `preserveModelChoice: false` so the
        // wipe is total — user explicitly asked for a from-scratch
        // state, including model choice.
        softReset(keychain: keychain, preserveModelChoice: false)
    }

    /// Delete every per-provider API key + the legacy shared entry via
    /// the `KeychainStoring` seam. Internal so regression tests can
    /// exercise the seam-routing without firing `RestartHelper.relaunch()`.
    static func clearAPIKeys(keychain: any KeychainStoring) {
        // Legacy shared keychain entry (pre per-provider refactor).
        try? keychain.delete(account: "jot.llm.apiKey")
        // Per-provider keychain entries.
        for provider in LLMConfiguration.bucketedProviders {
            try? keychain.delete(account: "jot.llm.\(provider.rawValue).apiKey")
        }
    }

    static func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jot.Jot"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "All", bundleID]
        try? task.run()
        task.waitUntilExit()
        RestartHelper.relaunch()
    }

    static func processPendingHardReset() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pendingHardResetMarkerURL.path) else { return }
        try? fm.removeItem(at: pendingHardResetMarkerURL)

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        try? fm.removeItem(at: appSupport.appendingPathComponent("Jot"))
        try? fm.removeItem(at: appSupport.appendingPathComponent("FluidAudio"))
        try? fm.removeItem(at: appSupport.appendingPathComponent("default.store"))
        try? fm.removeItem(at: appSupport.appendingPathComponent("default.store-shm"))
        try? fm.removeItem(at: appSupport.appendingPathComponent("default.store-wal"))
        try? fm.removeItem(at: library.appendingPathComponent("Logs/Jot"))
        if let bundleID = Bundle.main.bundleIdentifier {
            try? fm.removeItem(at: library.appendingPathComponent("Caches/\(bundleID)"))
            try? fm.removeItem(at: library.appendingPathComponent("HTTPStorages/\(bundleID)"))
        }
    }
}
