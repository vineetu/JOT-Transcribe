import AppKit
import Foundation
import KeyboardShortcuts
import SwiftUI

@MainActor
enum ResetActions {
    /// Phase 4 patch round 3: `keychain` seam threaded so per-provider
    /// API key deletion routes through `KeychainStoring` (production:
    /// `LiveKeychain`; harness: `StubKeychain`) instead of the static
    /// `KeychainHelper`. Closes the Phase 3 #29 Scope-A deferral.
    static func softReset(keychain: any KeychainStoring) {
        let defaults = UserDefaults.standard
        var keys: [String] = [
            "jot.llm.provider",
            // Legacy shared-bucket keys (pre per-provider refactor). Kept in
            // this list so reset still cleans up any stale value on a user
            // who ran an older build.
            "jot.llm.baseURL",
            "jot.llm.model",
            "jot.llm.transformPrompt",
            "jot.llm.rewritePrompt",
            "jot.transformEnabled"
        ]
        for provider in LLMConfiguration.bucketedProviders {
            keys.append("jot.llm.\(provider.rawValue).baseURL")
            keys.append("jot.llm.\(provider.rawValue).model")
        }
        for key in keys {
            defaults.removeObject(forKey: key)
        }

        clearAPIKeys(keychain: keychain)
        FirstRunState.shared.reset()

        KeyboardShortcuts.reset(
            .toggleRecording,
            .pasteLastTranscription,
            .articulate,
            .articulateCustom,
            .pushToTalk
        )

        RestartHelper.relaunch()
    }

    static func hardReset(keychain: any KeychainStoring) {
        UserDefaults.standard.set(true, forKey: "jot.pendingHardReset")
        softReset(keychain: keychain)
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
        guard UserDefaults.standard.bool(forKey: "jot.pendingHardReset") else { return }
        UserDefaults.standard.removeObject(forKey: "jot.pendingHardReset")

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Jot", isDirectory: true)

        let store = appSupport.appendingPathComponent("default.store")
        try? fm.removeItem(at: store)
        try? fm.removeItem(at: appSupport.appendingPathComponent("default.store-shm"))
        try? fm.removeItem(at: appSupport.appendingPathComponent("default.store-wal"))
        try? fm.removeItem(at: appSupport.appendingPathComponent("Recordings", isDirectory: true))
        try? fm.removeItem(at: appSupport.appendingPathComponent("Models", isDirectory: true))
    }
}
