import SwiftUI

/// Prominent advisory banner shown when Apple Intelligence is the active
/// provider for Cleanup / Rewrite. Apple's on-device Foundation Models
/// today are capacity-limited — Cleanup and Rewrite results are routinely
/// weaker than what cloud providers (OpenAI, Anthropic, Gemini) or even
/// local Ollama produce on structural rewrites, translation, and code.
///
/// We keep Apple Intelligence as the default for fresh installs because
/// it's private and zero-config, but a quiet 11pt secondary footnote
/// undersold how much the user's perception of *Jot* depends on the
/// provider they're routed to. This banner replaces the old footnote
/// with a bordered orange-tinted card so users see the tradeoff at the
/// moment they're choosing or reviewing their provider.
///
/// Reversible: when Apple ships a noticeably better on-device or Private
/// Cloud Compute model (likely WWDC 2026 + macOS 27.0 in fall), drop
/// this view from the two call sites and restore the original footnote.
struct AppleIntelligenceQualityBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Apple Intelligence quality is limited today")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text("Apple's on-device model can produce uneven results — especially for structural rewrites, translation, and code. It's private and runs on-device with no API key. For noticeably better Cleanup and Rewrite quality today, consider OpenAI, Anthropic, Gemini, or local Ollama. We'll revisit Apple Intelligence when Apple ships an upgraded model.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }
}
