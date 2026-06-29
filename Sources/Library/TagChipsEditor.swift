import SwiftData
import SwiftUI

/// Tags editor for a recording — chips + an inline add field. Placed BELOW the
/// shared `DetailHeader` in `RecordingDetailView` ONLY (design M2): the header
/// is shared with `RewriteSessionDetailView`, which has no `tags`, so tags must
/// never live inside it.
///
/// Tags are normalized on WRITE (trim + strip leading `#` + lowercase +
/// single-token) so the stored value is canonical and exact dedupe works
/// (design m3). Persistence is delegated to `onChange` so the owner controls
/// the `modelContext` save (mirrors the explicit-save pattern, not autosave).
struct TagChipsEditor: View {
    @Bindable var recording: Recording
    /// Called after a mutation so the owner can `try? context.save()`.
    var onChange: () -> Void

    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)

            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(recording.tags, id: \.self) { tag in
                    TagChip(tag: tag) { remove(tag) }
                }
                addField
            }
        }
    }

    private var addField: some View {
        TextField("Add tag", text: $newTag)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .frame(width: 90)
            .onSubmit(add)
            .accessibilityLabel("Add tag")
    }

    private func add() {
        let normalized = Self.normalize(newTag)
        newTag = ""
        guard !normalized.isEmpty, !recording.tags.contains(normalized) else { return }
        recording.tags.append(normalized)
        onChange()
    }

    private func remove(_ tag: String) {
        recording.tags.removeAll { $0 == tag }
        onChange()
    }

    /// Canonicalize a raw tag input: lowercase, trim, drop leading `#`, collapse
    /// internal whitespace into a single hyphen (single-token), cap length.
    /// Writing canonical values makes the `contains` dedupe exact.
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        s = parts.joined(separator: "-")
        return String(s.prefix(40))
    }
}

/// A single tag chip. Used both as a removable chip in the editor (pass
/// `onRemove`) and as a filter chip in the list (pass `selected`, no remove).
struct TagChip: View {
    let tag: String
    var selected: Bool = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.system(size: 11))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor.opacity(0.7))
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(selected ? 0.30 : 0.14)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(selected ? 0.6 : 0)))
        .foregroundStyle(Color.accentColor)
    }
}

/// Minimal wrapping layout (macOS 13+). Self-contained and used only by the tag
/// UI, so it can't affect existing surfaces. Width is taken from the proposal;
/// children flow left-to-right and wrap to a new line when they'd overflow.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, x - spacing)
        let resolvedWidth = maxWidth == .infinity ? max(widest, 0) : maxWidth
        return CGSize(width: resolvedWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sv.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
