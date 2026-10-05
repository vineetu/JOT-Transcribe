import SwiftUI

extension View {
    /// Keeps a live transcript's scroll view at its newest words while the
    /// user is reading at the bottom, and leaves it alone once they scroll up
    /// to read back; scrolling down to the bottom again resumes following.
    /// Apply to the `ScrollView`; `id` names the content `proxy` scrolls to.
    func followsNewText<V: Equatable>(_ value: V, id: String, proxy: ScrollViewProxy) -> some View {
        modifier(FollowsNewText(value: value, id: id, proxy: proxy))
    }
}

private struct FollowsNewText<V: Equatable>: ViewModifier {
    let value: V
    let id: String
    let proxy: ScrollViewProxy
    @State private var following = true

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                let atBottom = new.contentOffset.y + new.containerSize.height >= new.contentSize.height - 12
                if atBottom {
                    following = true
                } else if new.contentOffset.y < old.contentOffset.y {
                    // Moved up while the content didn't push it: the user
                    // scrolled back. New words only grow the content, and our
                    // own scroll only moves down, so neither lands here.
                    following = false
                }
            }
            .onChange(of: value) { _, _ in
                guard following else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
    }
}
