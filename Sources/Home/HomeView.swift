import SwiftUI

/// The Home page: big mic button + hint + last-transcription card.
///
/// Navigation to Recordings detail is routed through a closure the parent
/// (`RootView`) supplies, so this view has no direct knowledge of the
/// sidebar selection state.
struct HomeView: View {
    let onOpenRecording: (Recording) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 16)

                RecordButton()

                Text("Press ⌥Space or click to dictate")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer().frame(height: 8)

                LastTranscriptionCard(onOpen: onOpenRecording)
            }
            .padding(.top, 40)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
    }
}
