import AppKit
import Foundation
import KeyboardShortcuts
import SwiftUI

@MainActor
enum ResetActions {
    static func softReset() {
        let defaults = UserDefaults.standard
        for key in [
            "jot.llm.provider",
            "jot.llm.baseURL",
            "jot.llm.model",
            "jot.llm.transformPrompt",
            "jot.llm.rewritePrompt",
            "jot.transformEnabled"
        ] {
            defaults.removeObject(forKey: key)
        }

        LLMConfiguration.clearAPIKey()
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

    static func hardReset() {
        UserDefaults.standard.set(true, forKey: "jot.pendingHardReset")
        softReset()
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
