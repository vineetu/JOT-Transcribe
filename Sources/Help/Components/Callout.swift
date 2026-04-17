import SwiftUI

/// Labeled inset for cross-cutting asides (plan §4.2). Four variants:
/// `.note` (yellow), `.tip` (yellow), `.warning` (orange), `.verified`
/// (green). Tinted fill + tinted stroke + tinted leading SF Symbol;
/// body copy stays in `.primary` ink so the tint reads as structure.
struct Callout<Content: View>: View {
    enum Variant {
        case note
        case tip
        case warning
        case verified

        var symbol: String {
            switch self {
            case .note: return "info.circle.fill"
            case .tip: return "lightbulb.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .verified: return "checkmark.seal.fill"
            }
        }

        var label: String {
            switch self {
            case .note: return "Note"
            case .tip: return "Tip"
            case .warning: return "Warning"
            case .verified: return "Verified"
            }
        }

        var tint: Color {
            switch self {
            case .note, .tip: return .yellow
            case .warning: return .orange
            case .verified: return .green
            }
        }
    }

    let variant: Variant
    @ViewBuilder let content: () -> Content

    init(_ variant: Variant, @ViewBuilder content: @escaping () -> Content) {
        self.variant = variant
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: variant.symbol)
                .font(.system(size: 13))
                .foregroundStyle(variant.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(variant.label)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(variant.tint)

                content()
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(variant.tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(variant.tint.opacity(0.18), lineWidth: 1)
        )
    }
}
