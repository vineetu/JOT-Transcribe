import SwiftUI

/// What a registered theme supplies. Build variants provide these at launch
/// (see `ThemePacks`); the stock build registers none, so the only theme that
/// exists there is `.default`.
///
/// Every token has the same meaning as the matching `JotTheme` accessor. Colours
/// are appearance-aware, not appearance-forcing: supply dynamic colours and the
/// system appearance picks the variant.
protocol ThemeDescriptor: Sendable {
    /// Stable storage id (what `UserDefaults` holds). Must not be `"default"`.
    var id: String { get }
    var displayName: String { get }
    var blurb: String { get }
    var accent: Color { get }
    var windowBackground: Color { get }
    var sidebarBackground: Color { get }
    var pillSignal: Color { get }
    var pillBody: Color { get }
    /// Filename prefix for the theme's chime set, or nil for the stock chimes.
    var soundPrefix: String? { get }
    /// Bundled JPEG resource name for the backdrop art, or nil for none.
    var backdropImageName: String? { get }
    /// Replacement pill surface, or nil to keep the stock pill.
    @MainActor var pillSkin: (any PillSkin)? { get }
    /// Replacement rewrite-panel chrome, or nil to keep the stock panel.
    @MainActor var rewritePanelSkin: (any RewritePanelSkin)? { get }
}

extension ThemeDescriptor {
    @MainActor var rewritePanelSkin: (any RewritePanelSkin)? { nil }
}

/// An appearance theme.
///
/// **Default is the shipping look and must stay byte-identical to it.** Every
/// token below returns exactly what the app used before themes existed when
/// `self == .default`, so a user who never opens the picker sees no change at
/// all. That property is asserted in `ThemeTests`.
///
/// Tracked code knows only `.default` and an opaque `id`. Everything else comes
/// from a `ThemeDescriptor` registered at launch; with none registered (the
/// stock build) the accessors fold to the pre-theme values and the Appearance
/// section in Settings does not render at all.
///
/// Equality and hashing are by `id` only, so a theme read back from storage
/// compares equal to the registered one it names.
struct JotTheme: Hashable, Sendable {
    let id: String
    private let descriptor: (any ThemeDescriptor)?

    private init(id: String, descriptor: (any ThemeDescriptor)?) {
        self.id = id
        self.descriptor = descriptor
    }

    static let `default` = JotTheme(id: "default", descriptor: nil)

    static func == (lhs: JotTheme, rhs: JotTheme) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// `@AppStorage` key. Follows the `jot.<subsystem>.<setting>` convention.
    static let storageKey = "jot.appearance.theme"

    /// The value written to storage.
    var rawValue: String { id }

    // MARK: - Registry

    nonisolated(unsafe) private static var registered: [JotTheme] = []

    /// Add a theme. Called once per theme at launch, before any UI reads
    /// `current`. A duplicate id replaces the earlier registration.
    static func register(_ descriptor: any ThemeDescriptor) {
        guard descriptor.id != JotTheme.default.id, !descriptor.id.isEmpty else { return }
        let theme = JotTheme(id: descriptor.id, descriptor: descriptor)
        registered.removeAll { $0.id == theme.id }
        registered.append(theme)
        invalidateCache()
    }

    /// Default first, then registered themes in registration order.
    static var allCases: [JotTheme] { [.default] + registered }

    /// Resolve a stored raw value.
    ///
    /// **Any unrecognised or absent value resolves to `.default`.** This is what
    /// makes moving between builds safe: a value stored by a build that
    /// registered themes silently falls back to the standard look in a build
    /// that did not. Asserted in `ThemeTests`.
    static func resolve(_ raw: String?) -> JotTheme {
        guard let raw else { return .default }
        return registered.first { $0.id == raw } ?? .default
    }

    /// The theme currently stored. Non-observing read, for AppKit-side callers
    /// (the pill, the sound player) that are outside the SwiftUI environment.
    ///
    /// Cached: this is read on every render by every migrated colour call site,
    /// so it must not hit `UserDefaults` each time. `ThemeStore` invalidates on
    /// change; `nil` means "not yet resolved this launch".
    nonisolated(unsafe) private static var cached: JotTheme?

    static var current: JotTheme {
        if let cached { return cached }
        let resolved = resolve(UserDefaults.standard.string(forKey: storageKey))
        cached = resolved
        return resolved
    }

    /// Drop the cache so the next `current` re-reads storage. Called by
    /// `ThemeStore` on selection, and by tests that write the key directly.
    static func invalidateCache() { cached = nil }

    // MARK: - Tokens

    var displayName: String { descriptor?.displayName ?? "Default" }

    /// One-line description shown under the picker.
    var blurb: String { descriptor?.blurb ?? "The standard Jot look." }

    /// The app accent. `.default` returns `Color.accentColor` — the *same*
    /// value every call site used before themes existed — so migrating a call
    /// site is provably a no-op until the user actually picks a theme.
    var accent: Color { descriptor?.accent ?? Color.accentColor }

    /// The main window's ground, behind the detail pane. `.default` returns
    /// nil: no background is applied at all, so the stock build stays
    /// byte-identical — the same no-op guarantee `.tint(nil)` gives controls.
    var windowBackground: Color? { descriptor?.windowBackground }

    /// The sidebar's ground — a shade apart from `windowBackground` so the
    /// source list still reads as a distinct surface.
    var sidebarBackground: Color? { descriptor?.sidebarBackground }

    /// The pill's live-signal tint (waveform trail + state dots).
    ///
    /// `.default` keeps `Color(white: 0.82)` — the monochrome pill from the
    /// owner decision of 2026-07-16. That decision rejected following the *macOS
    /// system accent*, whose hue was unpredictable; a theme colour is chosen
    /// deliberately, so a non-default theme may tint the signal.
    var pillSignal: Color { descriptor?.pillSignal ?? Color(white: 0.82) }

    /// The pill body. Stays near-black in every theme — it floats over arbitrary
    /// desktop wallpaper, so it can be tinted but never lightened.
    var pillBody: Color { descriptor?.pillBody ?? .black }

    /// Filename prefix for this theme's chime set, or `nil` to use the stock
    /// chimes. See `SoundEffect.fileName(for:)`.
    var soundPrefix: String? { descriptor?.soundPrefix }

    /// This theme's pill surface, or nil for the stock pill.
    @MainActor var pillSkin: (any PillSkin)? { descriptor?.pillSkin }

    /// This theme's rewrite-panel chrome, or nil for the stock panel.
    @MainActor var rewritePanelSkin: (any RewritePanelSkin)? { descriptor?.rewritePanelSkin }

    // MARK: - Artwork

    /// Backdrop art behind the main window, the pill and the rewrite panel, or
    /// `nil` for no art (Default). The images are bundled only by variant
    /// builds, so a missing file simply means no art — every consumer falls
    /// back to the plain colour surfaces.
    var backdropImage: NSImage? {
        guard let name = descriptor?.backdropImageName else { return nil }
        // Misses are cached too (as nil): this is read on every render, and a
        // build without the art would otherwise hit the bundle each time.
        if let cached = Self.imageCache[name] { return cached }
        let image = Bundle.main.url(forResource: name, withExtension: "jpg").flatMap(NSImage.init(contentsOf:))
        Self.imageCache[name] = .some(image)
        return image
    }

    nonisolated(unsafe) private static var imageCache: [String: NSImage?] = [:]

    /// What the detail pane paints when the window backdrop is showing: clear,
    /// so the art (already veiled by `ThemeBackdrop`) comes through. Without art
    /// this is just `windowBackground`.
    var detailSurface: Color? {
        backdropImage == nil ? windowBackground : .clear
    }

    /// The sidebar over the backdrop: a light wash of its own ground so the
    /// source list still reads as a separate column.
    var sidebarSurface: Color? {
        guard let sidebarBackground else { return nil }
        return backdropImage == nil ? sidebarBackground : sidebarBackground.opacity(0.45)
    }
}

/// Launch-time hook for build variants that ship extra themes.
///
/// Tracked code never names the variant: it looks the loader class up by a
/// neutral runtime name. A build without that class registers nothing and runs
/// with `.default` only.
@objc protocol ThemePackLoading {
    @MainActor static func loadThemePacks()
}

enum ThemePacks {
    /// Runtime class name a variant defines with `@objc(...)`.
    static let loaderClassName = "JotThemePackLoader"

    /// Register any bundled themes. Idempotent enough to call once from
    /// `JotApp.init()`, before any scene or `ThemeStore` read.
    @MainActor static func bootstrap() {
        (NSClassFromString(loaderClassName) as? ThemePackLoading.Type)?.loadThemePacks()
    }
}

extension Color {
    /// 0xRRGGBB literal.
    init(hex: UInt32) { self = Color(nsColor: NSColor(rgb: hex)) }

    /// A colour that resolves per appearance. Uses `NSColor`'s dynamic provider
    /// so light/dark switching keeps working without `preferredColorScheme`.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// 0xRRGGBB literal. sRGB so the value matches the design tokens exactly.
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}
