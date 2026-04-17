import SwiftUI

/// Body-role prose wrapper (13.5 pt SF Pro regular, `.primary`).
///
/// Note: plan §4.5 argues that in the diagram-led end state "body prose"
/// only exists as a `Caption`, and a separate `BodyText` is unnecessary.
/// Phase 1 predates the diagrams, so we still have paragraph-length text
/// that doesn't live under a diagram; keeping `BodyText` lets those
/// paragraphs render in the correct typographic role now, and later
/// phases can collapse paragraphs into captions as the diagrams land.
struct BodyText: View {
    private let text: String

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
