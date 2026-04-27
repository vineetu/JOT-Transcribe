import SwiftData
import SwiftUI

public enum ShareAction: String, Equatable, Identifiable {
    case copy, reveal, email, view

    public var id: String { rawValue }

    var verb: String {
        switch self {
        case .copy: return "copy"
        case .reveal: return "reveal"
        case .email: return "share"
        case .view: return "view"
        }
    }
    var primaryTitle: String {
        switch self {
        case .copy: return "Copy log"
        case .reveal: return "Show in Finder"
        case .email: return "Send via email"
        case .view: return "View log"
        }
    }
}

struct PrivacyScanSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner: LogScanner
    let action: ShareAction
    let onProceed: (_ useRedacted: Bool, _ action: ShareAction) -> Void

    init(
        action: ShareAction,
        llmConfiguration: LLMConfiguration,
        onProceed: @escaping (Bool, ShareAction) -> Void
    ) {
        self.action = action
        self.onProceed = onProceed
        _scanner = StateObject(wrappedValue: LogScanner(llmConfiguration: llmConfiguration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            checklist
            if scanner.worst.isRed { redBanner }
            Spacer(minLength: 0)
            honestyBullet
            footerButtons
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task {
            if scanner.visibleResults.isEmpty && !scanner.isComplete {
                await scanner.run()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Before sharing your log").font(.system(size: 15, weight: .semibold))
                Text("Checking for anything sensitive before you \(action.verb) this file.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
        }
    }

    private var checklist: some View {
        VStack(spacing: 10) {
            ForEach(PrivacyCheckKind.allCases, id: \.rawValue) { kind in
                checklistRow(for: kind)
            }
        }
    }

    @ViewBuilder
    private func checklistRow(for kind: PrivacyCheckKind) -> some View {
        let result = scanner.visibleResults.first { $0.kind == kind }
        HStack {
            if let result {
                Image(systemName: result.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.isClean ? .green : .orange)
            } else if scanner.isComplete {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(kind.title).font(.system(size: 13))
            Spacer()
            if let result {
                Text(result.isClean ? "clean" : "\(result.findings.count) matches")
                    .font(.system(size: 11))
                    .foregroundStyle(result.isClean ? Color.secondary : Color.orange)
            }
        }
    }

    private var redBanner: some View {
        Text("An API key pattern was found. Sharing this log could leak credentials.")
            .font(.system(size: 12))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.3), lineWidth: 1))
    }

    private var honestyBullet: some View {
        Text("This scans the log file only. Recordings, transcripts, and clipboard contents live elsewhere and are not shared.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var footerButtons: some View {
        HStack {
            Text(scanner.stats).font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            if !scanner.isComplete {
                EmptyView()
            } else if scanner.worst.isClean {
                Button(action.primaryTitle) { onProceed(false, action); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                if scanner.worst.isRed {
                    Button("\(action.primaryTitle) anyway") { onProceed(false, action); dismiss() }
                        .buttonStyle(.borderless)
                } else {
                    Button("\(action.primaryTitle) anyway") { onProceed(false, action); dismiss() }
                        .buttonStyle(.bordered)
                }
                Button("Auto-redact and \(action.verb)") { onProceed(true, action); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
}
