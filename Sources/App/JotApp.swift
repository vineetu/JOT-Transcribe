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
                .environmentObject(appDelegate.recorder)
                .environmentObject(appDelegate.delivery)
                .environmentObject(PermissionsService.shared)
                .environment(\.transcriber, appDelegate.recorder.transcriber)
                .modelContainer(appDelegate.modelContainer)
        }

        JotSettings()
    }
}
