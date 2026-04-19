import SwiftUI

/// Search field used at the top of HelpPane. Drives per-card filtering.
///
/// Visual language matches the "field manual" aesthetic — thin ruled
/// border, monospace placeholder tag, hairline focus highlight. Not a
/// macOS SearchField because that rides the toolbar; this is inline at
/// the top of the pane content.
struct HelpSearchField: View {
    @Binding var text: String
    let resultCount: Int
    let totalCount: Int
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("", text: $text, prompt: Text("Search features, shortcuts, providers…"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .focused($isFocused)

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isFocused
                            ? Color.accentColor.opacity(0.6)
                            : Color.primary.opacity(0.12),
                        lineWidth: isFocused ? 1.0 : 0.5
                    )
            )
            .animation(.easeOut(duration: 0.1), value: isFocused)

            Text(resultLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 66, alignment: .trailing)
                .contentTransition(.numericText())
        }
    }

    private var resultLabel: String {
        if text.isEmpty {
            return "\(totalCount) features"
        } else if resultCount == 0 {
            return "no matches"
        } else if resultCount == 1 {
            return "1 match"
        } else {
            return "\(resultCount) matches"
        }
    }
}
