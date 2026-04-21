import SwiftUI

enum ResetKind {
    case soft, hard, permissions

    var title: String {
        switch self {
        case .soft: return "Reset settings"
        case .hard: return "Erase all data"
        case .permissions: return "Reset permissions"
        }
    }

    var clears: String {
        switch self {
        case .soft: return "AI provider, API key, prompts, keyboard shortcuts, Setup Wizard progress"
        case .hard: return "Everything above + all recordings, transcripts, audio files, Parakeet model (~600 MB)"
        case .permissions: return "macOS microphone, input monitoring, and accessibility grants"
        }
    }

    var keeps: String {
        switch self {
        case .soft: return "Recordings, transcripts, audio, Parakeet model, macOS permissions"
        case .hard: return "macOS permissions"
        case .permissions: return "Recordings, transcripts, audio, settings"
        }
    }

    var relaunchTarget: String {
        switch self {
        case .soft, .hard: return "Setup Wizard"
        case .permissions: return "macOS permission prompts"
        }
    }
}

struct ResetInfoPopover: View {
    let kind: ResetKind

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind.title).font(.system(size: 13, weight: .semibold))
            Divider()
            row(label: "Clears:", text: kind.clears)
            row(label: "Keeps:", text: kind.keeps)
            row(label: "Relaunches into:", text: kind.relaunchTarget)
        }
        .padding(12)
        .frame(width: 280)
    }

    private func row(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
