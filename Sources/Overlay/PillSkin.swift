import SwiftUI

/// A replacement look for the floating pill, supplied by a registered theme
/// (`JotTheme.pillSkin`). The stock build registers none and the pill renders
/// exactly as it always has.
///
/// A skin replaces only the capsule surface for the states it opts into. The
/// drag gesture, tap-to-expand and the hints under the pill stay stock, and
/// every state a skin returns nil for uses the stock pill unchanged.
///
/// An expanded layout that the skin draws itself also carries its own stop
/// hint, so the stock hint under the pill is hidden for it.
///
/// The layout and the surface are tied together: `layout(for:expanded:)` is
/// the ONE predicate for "is this state skinned", read by both the overlay
/// controller (size, clamp, hit-test) and the pill view, and `surface` is only
/// called for states it returned a layout for. `layout.hitRects` must cover
/// what `surface` draws, or the uncovered area is a click-through dead zone.
@MainActor
protocol PillSkin {
    /// Size and hit shape for `state`, or nil to use the stock pill.
    func layout(for state: PillViewModel.PillState, expanded: Bool) -> PillSkinLayout?

    /// The surface for `context.state`. Called only for states
    /// `layout(for:expanded:)` returned a layout for. The view reads live
    /// amplitude from the `AmplitudePublisher` environment object.
    func surface(context: PillSkinContext) -> AnyView
}

/// A skinned state's frame and hit/drag shape.
struct PillSkinLayout: Equatable {
    var size: CGSize
    /// Rects in the skin's own top-left coordinates (inside `size`). A point is
    /// on the pill when any rect contains it. Empty → the whole `size` rect.
    var hitRects: [CGRect]
}

/// What the stock pill already reads, handed to a skin.
struct PillSkinContext {
    var state: PillViewModel.PillState
    var expanded: Bool
    /// True while the streaming engine is active, even before the first
    /// partial lands (reserves the text lane, as the stock pill does).
    var isStreamingSession: Bool
    var reduceMotion: Bool
    /// Determinate rewrite / cleanup progress (0...1), nil when indeterminate.
    var progress: Double?
    /// Characters streamed so far by the rewrite / cleanup run.
    var streamedCharacters: Int
    /// The bound stop key, as the stock "Press … to stop" hint names it. A skin
    /// that draws its own hint (the stock one is hidden while it is expanded)
    /// shows this.
    var stopKeyLabel: String = ""
}

/// A pill's hit/drag shape: a few rects, hit when any contains the point.
struct PillHitRegion: Equatable {
    var rects: [CGRect]

    static let empty = PillHitRegion(rects: [])

    func contains(_ point: CGPoint) -> Bool {
        rects.contains { $0.contains(point) }
    }
}

/// `contentShape` for a skinned surface, built from the same rects the
/// controller hit-tests, so SwiftUI taps and AppKit hit-testing agree.
struct PillHitShape: Shape {
    var rects: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if rects.isEmpty {
            path.addRect(rect)
        } else {
            for r in rects { path.addRect(r) }
        }
        return path
    }
}
