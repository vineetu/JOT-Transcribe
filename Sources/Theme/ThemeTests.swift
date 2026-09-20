#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// Launch-time assertions for the theme system, in the same in-process style as
/// `HelpInfraTests` (the XCTest target is not the project's test gate).
///
/// The point of these is the one property the whole feature rests on: **a user
/// who never picks a theme must get exactly the pre-theme app.** If that ever
/// stops being true, this trips at launch in DEBUG rather than shipping.
enum ThemeTests {
    static func runAll() {
        assertDefaultIsUnchanged()
        assertUnknownRawValueFallsBack()
        assertRoundTrip()
        assertDefaultHasNoThemedSounds()
        assertEveryCaseIsComplete()
    }

    /// The no-op guarantee: Default's tokens equal the values the app used
    /// before themes existed.
    private static func assertDefaultIsUnchanged() {
        let d = JotTheme.default
        assert(d.accent == Color.accentColor,
               "Default accent must be Color.accentColor — migrating a call site has to be a no-op")
        assert(d.pillSignal == Color(white: 0.82),
               "Default pill signal must stay the 2026-07-16 monochrome ink-grey")
        assert(d.pillBody == Color.black, "Default pill body must stay black")
        assert(d.soundPrefix == nil, "Default must use the stock chimes")
    }

    /// A stored value from another build (or a corrupt one) must degrade to
    /// Default, never crash or strand the user on a theme they can't see.
    private static func assertUnknownRawValueFallsBack() {
        assert(JotTheme.resolve(nil) == .default, "absent value → default")
        assert(JotTheme.resolve("") == .default, "empty value → default")
        assert(JotTheme.resolve("nonsense") == .default, "unknown value → default")
        // The real cross-build case: a value stored by a build that registered
        // themes, read by one that did not.
        assert(JotTheme.resolve("unregistered-id") == .default,
               "an unregistered theme id must fall back cleanly to Default")
    }

    private static func assertRoundTrip() {
        for theme in JotTheme.allCases {
            assert(JotTheme.resolve(theme.rawValue) == theme,
                   "\(theme.rawValue) must round-trip through storage")
        }
    }

    private static func assertDefaultHasNoThemedSounds() {
        assert(SoundEffect.allCases.allSatisfy { $0.fileName(for: .default) == $0.fileName },
               "Default must resolve to the stock chime filenames unchanged")
    }

    /// Every case must supply every token — catches a case added without its
    /// colours, which would otherwise silently render as Default.
    private static func assertEveryCaseIsComplete() {
        for theme in JotTheme.allCases {
            assert(!theme.displayName.isEmpty, "\(theme.rawValue) needs a display name")
            assert(!theme.blurb.isEmpty, "\(theme.rawValue) needs a blurb")
            if theme != .default {
                // A theme need not ship chimes, but it must be visually
                // distinguishable or it is pointless.
                assert(theme.pillSignal != JotTheme.default.pillSignal,
                       "\(theme.rawValue) should tint the pill signal, else it is indistinguishable")
            }
            // Any theme that DOES claim a chime set must name a non-empty prefix.
            if let prefix = theme.soundPrefix {
                assert(!prefix.isEmpty, "\(theme.rawValue) has an empty sound prefix")
            }
        }
    }
}
#endif
