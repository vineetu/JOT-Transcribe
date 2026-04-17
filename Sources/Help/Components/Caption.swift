import SwiftUI

/// The 1–2 sentence caption placed directly beneath a diagram (plan §4.2).
///
/// 13.5 pt SF Pro regular, `.primary` foreground, 1.45-ish line height.
struct Caption: View {
    private let text: String

    // The 1–2-sentence cap (plan §P5 redundancy + §P7 chunking) is enforced
    // by author convention and code review, NOT at runtime. Naive boundary
    // detection (splitting on `.!?`) misbehaves on inputs like `e.g.` or
    // `http://localhost:11434`, so we do not assert at all. Keep author
    // judgment as the source of truth.
    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13.5))
            .lineSpacing(2.5)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
