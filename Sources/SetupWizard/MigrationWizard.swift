import AppKit
import SwiftUI

@MainActor
enum SingleOrChordMigrationWizardPresenter {
    private static var controller: SingleOrChordMigrationWindowController?

    static func presentIfNeeded(wasSetupCompleteAtLaunch: Bool) {
        guard SingleKeyMigration.shouldPresentSingleOrChordWizard(
            wasSetupCompleteAtLaunch: wasSetupCompleteAtLaunch
        ) else { return }

        present(ambiguousActions: SingleKeyMigration.ambiguousActions())
    }

    private static func present(ambiguousActions: [SingleKeyMigration.AmbiguousAction]) {
        if let controller {
            controller.presentAppModal()
            return
        }

        let model = SingleOrChordMigrationViewModel(
            ambiguousActions: ambiguousActions,
            onFinish: {
                SingleKeyMigration.markSingleOrChordMigrationCompleted()
                closeWindow()
            }
        )
        let wc = SingleOrChordMigrationWindowController(
            model: model,
            onClose: {
                controller = nil
                NSApp.stopModal()
            }
        )
        controller = wc
        wc.presentAppModal()
    }

    private static func closeWindow() {
        controller?.close()
        controller = nil
    }
}

@MainActor
private final class SingleOrChordMigrationViewModel: ObservableObject {
    @Published var stepIndex: Int = 0
    @Published var selectedTriggerType: SingleKey.TriggerType?

    let ambiguousActions: [SingleKeyMigration.AmbiguousAction]
    private let onFinish: () -> Void

    init(
        ambiguousActions: [SingleKeyMigration.AmbiguousAction],
        onFinish: @escaping () -> Void
    ) {
        self.ambiguousActions = ambiguousActions
        self.onFinish = onFinish
    }

    var stepCount: Int { 1 + ambiguousActions.count }
    var isAnnouncement: Bool { stepIndex == 0 }

    var currentAmbiguity: SingleKeyMigration.AmbiguousAction? {
        let index = stepIndex - 1
        guard ambiguousActions.indices.contains(index) else { return nil }
        return ambiguousActions[index]
    }

    func continueFromAnnouncement() {
        guard !ambiguousActions.isEmpty else {
            onFinish()
            return
        }
        stepIndex = 1
        selectedTriggerType = nil
    }

    func keepSelectedTrigger() {
        guard let currentAmbiguity,
              let selectedTriggerType
        else { return }

        SingleKeyMigration.setTriggerType(selectedTriggerType, for: currentAmbiguity.action)
        let nextStep = stepIndex + 1
        guard nextStep < stepCount else {
            onFinish()
            return
        }
        stepIndex = nextStep
        self.selectedTriggerType = nil
    }
}

@MainActor
private final class SingleOrChordMigrationWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(model: SingleOrChordMigrationViewModel, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let contentSize = NSSize(width: 520, height: 360)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        window.center()
        window.setFrameAutosaveName("")

        let rootView = SingleOrChordMigrationWizardView(model: model)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        window.contentView = hostingView
        window.setContentSize(contentSize)
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        window.minSize = frameSize
        window.maxSize = frameSize

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func presentAppModal() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

@MainActor
private struct SingleOrChordMigrationWizardView: View {
    @ObservedObject var model: SingleOrChordMigrationViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 18)

            Divider().opacity(0.4)

            Group {
                if model.isAnnouncement {
                    announcementStep
                } else if let ambiguity = model.currentAmbiguity {
                    ambiguityStep(ambiguity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(30)

            Divider().opacity(0.4)

            footer
                .padding(.horizontal, 30)
                .padding(.vertical, 16)
        }
        .frame(width: 520, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Shortcut update")
                .font(.system(size: 22, weight: .semibold))
            Spacer()
            Text("Step \(model.stepIndex + 1) of \(model.stepCount)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var announcementStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jot shortcuts now use one trigger per action.")
                .font(.system(size: 15, weight: .semibold))
            Text("Each action can use either a single key or a chord. This keeps global shortcuts predictable and prevents the same action from firing through two bindings.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.ambiguousActions.isEmpty {
                Text("A few of your shortcuts have both triggers set. Choose which one to keep on the next step\(model.ambiguousActions.count == 1 ? "" : "s").")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    private func ambiguityStep(_ ambiguity: SingleKeyMigration.AmbiguousAction) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(ambiguity.action.displayName)
                    .font(.system(size: 18, weight: .semibold))
                Text("You have both triggers bound. Keep one:")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                choiceRow(
                    type: .singleKey,
                    label: ambiguity.singleKey.displayName
                )
                choiceRow(
                    type: .chord,
                    label: ambiguity.chordDescription
                )
            }

            Text("The other trigger will be removed.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    private func choiceRow(type: SingleKey.TriggerType, label: String) -> some View {
        Button {
            model.selectedTriggerType = type
        } label: {
            HStack(spacing: 10) {
                Image(systemName: model.selectedTriggerType == type ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(model.selectedTriggerType == type ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if model.isAnnouncement {
                Button("Continue") {
                    model.continueFromAnnouncement()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Keep") {
                    model.keepSelectedTrigger()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedTriggerType == nil)
            }
        }
    }
}
