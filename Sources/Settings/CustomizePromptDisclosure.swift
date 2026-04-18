import SwiftUI

/// Inline disclosure row that exposes an editable system prompt.
///
/// Collapsed state: a chevron + small secondary label (e.g. "Customize prompt").
/// Expanded state: a fixed-height monospaced `TextEditor` (~140 pt, internal
/// scrolling so the expand/collapse doesn't thrash the window height) plus a
/// trailing "Reset to default" button.
///
/// The monospace font signals "this is a system string; edit with care."
/// The fixed height is intentional — the unified app window is sized to the
/// tallest pane's natural height, and a freely-growing editor would undermine
/// that sizing strategy (see `docs/plans/app-ui-unification.md` §"Disclosure-
/// expand height behavior").
///
/// Reset enablement compares whitespace-trimmed equality so stray trailing
/// newlines or leading spaces don't leave Reset visibly enabled on a prompt
/// that is semantically identical to the default (see §"Reset-to-default
/// comparison (I6)").
struct CustomizePromptDisclosure: View {
    struct Info {
        let title: String
        let body: String
        let helpAnchor: String?
    }

    /// Row label shown next to the chevron (e.g. "Customize prompt").
    let label: String

    /// Two-way binding to the user-editable prompt string.
    @Binding var text: String

    /// The default prompt used by "Reset to default".
    let defaultValue: String

    /// Optional info popover rendered beside the disclosure.
    let info: Info?

    @State private var isExpanded: Bool = false

    init(label: String, text: Binding<String>, defaultValue: String, info: Info? = nil) {
        self.label = label
        self._text = text
        self.defaultValue = defaultValue
        self.info = info
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.12))
                        )

                    HStack {
                        Spacer()
                        Button("Reset to default") {
                            text = defaultValue
                        }
                        .controlSize(.small)
                        .disabled(
                            text.trimmingCharacters(in: .whitespacesAndNewlines)
                                == defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack {
                    Text(label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .layoutPriority(1)

            if let info {
                InfoPopoverButton(
                    title: info.title,
                    body: info.body,
                    helpAnchor: info.helpAnchor
                )
            }
        }
    }
}
