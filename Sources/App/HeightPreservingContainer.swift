import SwiftUI

/// Window-height-preserving wrapper for the unified window's detail column.
///
/// The unified window is pinned to the tallest pane's natural height (design
/// doc §I2 / §E). Per-pane resize animations are jittery and widely considered
/// an antipattern (see the "HeightPreservingTabView" TIL cited in the design
/// doc). This container implements the same idiom adapted to a sidebar-driven
/// pane switcher:
///
///   1. Each child reports its intrinsic height via a `PreferenceKey`.
///   2. We track the running `max()` in `@State observedMax`.
///   3. We apply `.frame(height: observedMax)` once we've observed a value.
///
/// `observedMax` is **monotonic-non-decreasing** across the session — once a
/// pane has grown the window, subsequent visits to shorter panes keep that
/// height rather than shrink. Users never see a downward jump. The first
/// time a previously-unseen pane becomes visible the window can grow once;
/// from then on the height is stable.
struct HeightPreservingContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @State private var observedMax: CGFloat = 0

    var body: some View {
        content()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: PaneHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                }
            )
            .onPreferenceChange(PaneHeightPreferenceKey.self) { newHeight in
                // Guard against the zero-size measurement that GeometryReader
                // reports before a child has laid out — picking it up as the
                // "max" would lock the container flat.
                guard newHeight > 0 else { return }
                if newHeight > observedMax {
                    observedMax = newHeight
                }
            }
            .frame(height: observedMax > 0 ? observedMax : nil)
    }
}

/// Carries the current child's intrinsic height up to
/// `HeightPreservingContainer`. The reducer takes the `max()` so sibling
/// measurements within a single layout pass can't clobber each other.
private struct PaneHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
