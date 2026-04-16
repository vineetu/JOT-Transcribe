import SwiftUI
import FluidAudio
import KeyboardShortcuts

@main
struct JotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var firstRunState = FirstRunState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(firstRunState)
        }

        JotSettings()
    }
}
