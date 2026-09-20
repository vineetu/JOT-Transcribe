import SwiftUI

/// Paints a theme's ground behind a scrolling container.
///
/// SwiftUI's `List` and `Form` draw their own opaque background, so a colour
/// applied underneath is simply not visible — the reason the first theme pass
/// looked like nothing had changed. Hiding the scroll content background is
/// what lets the ground through, but it is only correct to hide it when a
/// replacement is actually supplied: with no theme colour the system's own
/// sidebar/form material must keep drawing, untouched.
///
/// Hence the optional. `nil` (the Default theme) is a genuine no-op — no
/// background modifier, no hidden scroll background — which preserves the
/// "Default is byte-identical to pre-theme" guarantee that ThemeTests asserts.
extension View {
    @ViewBuilder
    func themedSurface(_ color: Color?) -> some View {
        if let color {
            self
                .scrollContentBackground(.hidden)
                .background(color.ignoresSafeArea())
        } else {
            self
        }
    }
}

/// A theme's artwork, filling whatever it backs, with a veil in the theme's
/// own ground colour on top so text laid over it stays readable. The art is
/// meant to be *felt* behind the UI, never to compete with it.
struct ThemeBackdrop: View {
    let theme: JotTheme
    /// How much of the ground colour covers the art (0 = raw art).
    var veil: Double = 0.72

    var body: some View {
        if let image = theme.backdropImage {
            // `Color.clear` takes exactly the proposed size; the fill-mode art
            // rides in an overlay so it can never size (and so spill past)
            // the surface it backs.
            Color.clear
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
                .overlay {
                    (theme.windowBackground ?? Color(nsColor: .windowBackgroundColor))
                        .opacity(veil)
                }
                .allowsHitTesting(false)
        }
    }
}

/// Dark glass over the theme art, for the always-dark floating surfaces (the
/// pill). Art first, then a near-black scrim so white text keeps its
/// contrast, then a hairline in the theme's signal colour. Themes without art
/// get exactly the old solid fill.
struct ThemedPillSurface<S: InsettableShape>: View {
    let shape: S
    /// Theme to draw; nil reads `JotTheme.current` (snapshot tests pass one).
    var theme: JotTheme? = nil

    var body: some View {
        let theme = self.theme ?? JotTheme.current
        ZStack {
            shape.fill(theme.pillBody)
            if let image = theme.backdropImage {
                // Bounded to the shape's own frame: `Color.clear` takes the
                // proposed size and the fill-mode art rides in an overlay, so
                // the art never sizes the surface or spills past the shape.
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 2)
                    }
                    .clipped()
                    .clipShape(shape)
                shape.fill(
                    LinearGradient(
                        colors: [theme.pillBody.opacity(0.45), theme.pillBody.opacity(0.72)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                shape.strokeBorder(theme.pillSignal.opacity(0.55), lineWidth: 1)
            }
        }
    }
}
