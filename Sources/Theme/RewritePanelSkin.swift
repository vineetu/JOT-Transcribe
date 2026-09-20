import SwiftUI

/// A replacement look for the rewrite instruction panel, supplied by a
/// registered theme (`JotTheme.rewritePanelSkin`). The stock build registers
/// none and the panel renders exactly as it always has.
///
/// A skin restyles the panel's chrome only: the content, controls, focus
/// handling and key behaviour stay stock.
@MainActor
protocol RewritePanelSkin {
    /// The panel follows the system appearance (it is a typing surface), so
    /// the skin supplies a style per scheme.
    func style(for colorScheme: ColorScheme) -> RewritePanelStyle
}

/// What a panel skin paints.
struct RewritePanelStyle {
    /// Everything under the content, drawn inside the panel's rounded clip:
    /// art, glass, tint, decoration. Must not take hits or size the panel.
    var ground: AnyView
    var border: Color
    /// Header icon, mic signal, title pill and the text field's ring glow.
    var accent: Color
    /// Replaces the header's stock symbol, or nil to keep it.
    var headerIcon: AnyView?
    var fieldFill: Color
    var fieldRing: Color
    var fieldGlow: Color
    var chipFill: Color
}
