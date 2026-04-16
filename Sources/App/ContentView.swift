import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var firstRunState: FirstRunState

    var body: some View {
        VStack(spacing: 12) {
            Text("Jot")
                .font(.largeTitle.bold())
            Text("Press a hotkey, speak, paste at cursor.")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
        .padding()
    }
}
