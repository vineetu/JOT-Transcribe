import Foundation

/// Canonical slug registry for the redesigned Help tab.
///
/// Single source of truth referenced by:
///   * `HelpBasicsView` / `HelpAdvancedView` / `HelpTroubleshootingView` —
///     to look up titles, tab membership, and isExpandable state when
///     rendering surfaces.
///   * `HelpNavigator.show(feature:)` — to route two-phase deep-links
///     (switch tab → expand row → scroll → highlight pulse).
///   * The future chatbot `ShowFeatureTool` — to reject non-deep-linkable
///     slugs before invoking the navigator.
///   * Search — every searchable surface reports its slug and the state
///     uses it to decide whether a hero should be forced visible because
///     one of its sub-rows matched.
///
/// The catalog comes from the Help redesign spec v1 §14. Keep this file
/// exhaustive: adding a surface means adding a `Feature` entry; removing
/// one means deleting it. Tests in `#if DEBUG` below assert both "all
/// required slugs present" and "no extras."
public struct Feature: Identifiable, Equatable, Hashable, Sendable {
    /// The slug. Stable across releases — used by Settings popovers,
    /// chatbot deep-links, and persisted user state (search queries in
    /// telemetry-free sessions don't persist, but future URL schemes
    /// might).
    public let id: String

    public var slug: String { id }

    /// User-facing name — shown on the card / row.
    public let title: String

    /// Which Help tab this feature lives on.
    public let tab: HelpTab

    /// What kind of surface renders this feature — drives how the
    /// navigator performs the deep-link (scroll only vs. expand-then-
    /// scroll, which container to scroll inside).
    public let surface: Surface

    /// For sub-rows, the hero slug they belong under (e.g. `"dictation"`).
    /// `nil` for heroes, Advanced cards, and Troubleshooting cards.
    public let parentHeroId: String?

    /// The slug the navigator should expand BEFORE scrolling. For hero
    /// cards and expandable sub-rows, equals `id`. For Advanced and
    /// Troubleshooting cards (which expand in place on tap), equals
    /// `id`. For plain (non-expandable) sub-rows, `nil` — they aren't
    /// deep-linkable.
    public let expandableRowId: String?

    /// Whether this feature is a valid tool target / deep-link target.
    /// The 5 plain sub-rows per chatbot spec §5 are NOT deep-linkable —
    /// the bot may mention them by name but never call `showFeature` for
    /// them. Everything else (heroes, expandable sub-rows, Advanced
    /// cards, Troubleshooting cards) is true.
    public let isDeepLinkable: Bool

    /// Sharp-fix rule from chatbot spec §7: the card carries a specific
    /// terminal command the model must NOT include in its answer — users
    /// read the exact command from the card, not from the chatbot
    /// output. True only for `recording-wont-start` and
    /// `hotkey-stopped-working`.
    public let commandOnCard: Bool

    public init(
        id: String,
        title: String,
        tab: HelpTab,
        surface: Surface,
        parentHeroId: String? = nil,
        expandableRowId: String? = nil,
        isDeepLinkable: Bool = true,
        commandOnCard: Bool = false
    ) {
        self.id = id
        self.title = title
        self.tab = tab
        self.surface = surface
        self.parentHeroId = parentHeroId
        self.expandableRowId = expandableRowId
        self.isDeepLinkable = isDeepLinkable
        self.commandOnCard = commandOnCard
    }
}

/// The three tabs inside the unified Help surface.
public enum HelpTab: String, CaseIterable, Hashable, Sendable {
    case basics
    case advanced
    case troubleshooting

    public var title: String {
        switch self {
        case .basics: return "Basics"
        case .advanced: return "Advanced"
        case .troubleshooting: return "Troubleshooting"
        }
    }
}

/// What kind of surface renders the feature. Used by the navigator to
/// pick between "scroll only" and "expand then scroll" flows.
public enum Surface: String, Hashable, Sendable {
    /// A hero card (Dictation / Cleanup / Articulate) on the Basics tab.
    case hero
    /// A sub-row beneath a hero on the Basics tab. Plain sub-rows
    /// (isDeepLinkable == false) still get this surface kind.
    case subRow
    /// A card inside one of the four Advanced sections.
    case advancedCard
    /// A card in the Troubleshooting grid.
    case troubleshootingCard
}

// MARK: - Catalog

extension Feature {
    /// Lookup a feature by its slug.
    public static func bySlug(_ slug: String) -> Feature? {
        Self.index[slug]
    }

    /// Every feature in the Help tab, in a deterministic order (Basics
    /// heroes + sub-rows in spec order, then Advanced in spec order, then
    /// Troubleshooting in spec order).
    public static let all: [Feature] = makeAll()

    /// Precomputed slug → Feature map. O(1) lookups at runtime.
    private static let index: [String: Feature] = {
        var dict: [String: Feature] = [:]
        for feature in Self.all {
            dict[feature.slug] = feature
        }
        return dict
    }()

    // MARK: Builder

    // swiftlint:disable:next function_body_length
    private static func makeAll() -> [Feature] {
        var features: [Feature] = []

        // ---------------- Basics ----------------

        // Hero: Dictation
        features.append(Feature(
            id: "dictation",
            title: "Dictation",
            tab: .basics,
            surface: .hero,
            expandableRowId: "dictation"
        ))

        // Dictation sub-rows (7, all expandable). `auto-transcribe` and
        // `re-transcribe` were removed from the Basics tab — the feature
        // inventory they described is adequately covered by the hero
        // subtitle and the expandable rows below it.
        features.append(dictationSubRow(id: "toggle-recording", title: "Toggle recording"))
        features.append(dictationSubRow(id: "push-to-talk", title: "Push to talk"))
        features.append(dictationSubRow(id: "cancel-recording", title: "Cancel recording"))
        features.append(dictationSubRow(id: "any-length", title: "Any-length recordings"))
        features.append(dictationSubRow(id: "on-device-transcription", title: "On-device transcription"))
        features.append(dictationSubRow(id: "multilingual", title: "Multilingual (25 languages)"))
        features.append(dictationSubRow(id: "custom-vocabulary", title: "Custom vocabulary"))

        // Hero: Cleanup
        features.append(Feature(
            id: "cleanup",
            title: "Cleanup",
            tab: .basics,
            surface: .hero,
            expandableRowId: "cleanup"
        ))

        // Cleanup sub-rows (4). Plain: cleanup-fallback, cleanup-raw-preserved.
        features.append(cleanupSubRow(id: "cleanup-providers", title: "Choose a provider"))
        features.append(cleanupSubRow(id: "cleanup-prompt", title: "Editable prompt"))
        features.append(cleanupSubRow(id: "cleanup-fallback", title: "Graceful fallback on failure", plain: true))
        features.append(cleanupSubRow(id: "cleanup-raw-preserved", title: "Raw + cleaned both saved", plain: true))

        // Hero: Articulate
        features.append(Feature(
            id: "articulate",
            title: "Articulate",
            tab: .basics,
            surface: .hero,
            expandableRowId: "articulate"
        ))

        // Articulate sub-rows (3, all expandable). `articulate-shared-prompt`
        // was removed — the shared invariants block is an implementation
        // detail visible when the user opens the prompt editor, not a
        // user-facing surface that warrants its own Help row.
        features.append(articulateSubRow(id: "articulate-custom", title: "Articulate (Custom)"))
        features.append(articulateSubRow(id: "articulate-fixed", title: "Articulate (Fixed)"))
        features.append(articulateSubRow(id: "articulate-intent-classifier", title: "Intent classifier"))

        // ---------------- Advanced ----------------

        // AI providers (6)
        features.append(advancedCard(id: "ai-apple-intelligence", title: "Apple Intelligence"))
        features.append(advancedCard(id: "ai-cloud-providers", title: "OpenAI · Anthropic · Gemini"))
        features.append(advancedCard(id: "ai-ollama", title: "Ollama"))
        features.append(advancedCard(id: "ai-custom-base-url", title: "Custom base URL"))
        features.append(advancedCard(id: "ai-editable-prompts", title: "Editable prompts"))
        features.append(advancedCard(id: "ai-test-connection", title: "Test Connection"))

        // System (4)
        features.append(advancedCard(id: "sys-launch-at-login", title: "Launch at login"))
        features.append(advancedCard(id: "sys-retention", title: "Retention"))
        features.append(advancedCard(id: "sys-hide-to-tray", title: "Hide to tray"))
        features.append(advancedCard(id: "sys-reset-scopes", title: "Reset scopes"))

        // Input (4). `input-vocabulary` is a catalog alias of `custom-vocabulary`
        // per spec §14 — kept as its own entry so the Input section card
        // resolves to a slug, while the chatbot and Settings popovers can
        // still link to the authoritative `custom-vocabulary` Basics sub-row.
        features.append(advancedCard(id: "input-device", title: "Input device"))
        features.append(advancedCard(id: "input-vocabulary", title: "Custom vocabulary"))
        features.append(advancedCard(id: "input-bluetooth", title: "Bluetooth mic handling"))
        features.append(advancedCard(id: "input-silent-capture", title: "Silent-capture detection"))

        // Sounds (3)
        features.append(advancedCard(id: "sound-recording-chimes", title: "Recording chimes"))
        features.append(advancedCard(id: "sound-transcription-complete", title: "Transcription complete"))
        features.append(advancedCard(id: "sound-error-chime", title: "Error chime"))

        // ---------------- Troubleshooting ----------------

        // Existing (8)
        features.append(troubleshootingCard(id: "permissions", title: "Permissions"))
        features.append(troubleshootingCard(id: "modifier-required", title: "Modifier required"))
        features.append(troubleshootingCard(id: "bluetooth-redirect", title: "Bluetooth mic redirect"))
        features.append(troubleshootingCard(id: "shortcut-conflicts", title: "Shortcut conflicts"))
        features.append(troubleshootingCard(
            id: "recording-wont-start",
            title: "Recording won't start?",
            commandOnCard: true
        ))
        features.append(troubleshootingCard(
            id: "hotkey-stopped-working",
            title: "Hotkey stopped working?",
            commandOnCard: true
        ))
        features.append(troubleshootingCard(id: "resetting-jot", title: "Resetting Jot"))
        features.append(troubleshootingCard(id: "report-issue", title: "Report an issue"))

        // New AI cards (3)
        features.append(troubleshootingCard(id: "ai-unavailable", title: "AI unavailable"))
        features.append(troubleshootingCard(id: "ai-connection-failed", title: "AI connection failed"))
        features.append(troubleshootingCard(id: "articulate-bad-results", title: "Articulate giving bad results?"))

        return features
    }

    // MARK: Factories

    private static func dictationSubRow(id: String, title: String, plain: Bool = false) -> Feature {
        Feature(
            id: id,
            title: title,
            tab: .basics,
            surface: .subRow,
            parentHeroId: "dictation",
            expandableRowId: plain ? nil : id,
            isDeepLinkable: !plain
        )
    }

    private static func cleanupSubRow(id: String, title: String, plain: Bool = false) -> Feature {
        Feature(
            id: id,
            title: title,
            tab: .basics,
            surface: .subRow,
            parentHeroId: "cleanup",
            expandableRowId: plain ? nil : id,
            isDeepLinkable: !plain
        )
    }

    private static func articulateSubRow(id: String, title: String, plain: Bool = false) -> Feature {
        Feature(
            id: id,
            title: title,
            tab: .basics,
            surface: .subRow,
            parentHeroId: "articulate",
            expandableRowId: plain ? nil : id,
            isDeepLinkable: !plain
        )
    }

    private static func advancedCard(id: String, title: String) -> Feature {
        Feature(
            id: id,
            title: title,
            tab: .advanced,
            surface: .advancedCard,
            expandableRowId: id
        )
    }

    private static func troubleshootingCard(
        id: String,
        title: String,
        commandOnCard: Bool = false
    ) -> Feature {
        Feature(
            id: id,
            title: title,
            tab: .troubleshooting,
            surface: .troubleshootingCard,
            expandableRowId: id,
            commandOnCard: commandOnCard
        )
    }
}

// MARK: - Helpers for consumers

extension Feature {
    /// Every feature on a given tab, in catalog order.
    public static func all(on tab: HelpTab) -> [Feature] {
        Self.all.filter { $0.tab == tab }
    }

    /// All sub-rows under a specific hero, in catalog order.
    public static func subRows(of heroSlug: String) -> [Feature] {
        Self.all.filter { $0.surface == .subRow && $0.parentHeroId == heroSlug }
    }

    /// Resolve the hero for a given feature — `self` if it's already a
    /// hero, the parent hero if it's a Basics sub-row, otherwise `nil`.
    public var hero: Feature? {
        switch surface {
        case .hero:
            return self
        case .subRow:
            guard let parentHeroId else { return nil }
            return Feature.bySlug(parentHeroId)
        case .advancedCard, .troubleshootingCard:
            return nil
        }
    }
}

// MARK: - Debug invariants

#if DEBUG
extension Feature {
    /// Slugs that must NOT be deep-linkable. After the removal of
    /// `auto-transcribe`, `re-transcribe`, and `articulate-shared-prompt`
    /// from the Basics tab, only the two Cleanup plain rows remain.
    static let plainSubRowSlugs: Set<String> = [
        "cleanup-fallback",
        "cleanup-raw-preserved",
    ]

    /// Slugs that must carry `commandOnCard == true` (chatbot spec §7
    /// sharp-fix rule).
    static let commandOnCardSlugs: Set<String> = [
        "recording-wont-start",
        "hotkey-stopped-working",
    ]

    /// Every slug the redesign spec §14 enumerates. Used by the test
    /// asserting catalog completeness.
    static let expectedSlugs: Set<String> = [
        // Heroes
        "dictation", "cleanup", "articulate",
        // Dictation sub-rows (7 — removed: auto-transcribe, re-transcribe)
        "toggle-recording", "push-to-talk", "cancel-recording", "any-length",
        "on-device-transcription", "multilingual", "custom-vocabulary",
        // Cleanup sub-rows
        "cleanup-providers", "cleanup-prompt", "cleanup-fallback",
        "cleanup-raw-preserved",
        // Articulate sub-rows (3 — removed: articulate-shared-prompt)
        "articulate-custom", "articulate-fixed", "articulate-intent-classifier",
        // Advanced cards
        "ai-apple-intelligence", "ai-cloud-providers", "ai-ollama",
        "ai-custom-base-url", "ai-editable-prompts", "ai-test-connection",
        "sys-launch-at-login", "sys-retention", "sys-hide-to-tray",
        "sys-reset-scopes",
        "input-device", "input-vocabulary", "input-bluetooth",
        "input-silent-capture",
        "sound-recording-chimes", "sound-transcription-complete",
        "sound-error-chime",
        // Troubleshooting
        "permissions", "modifier-required", "bluetooth-redirect",
        "shortcut-conflicts", "recording-wont-start", "hotkey-stopped-working",
        "resetting-jot", "report-issue",
        "ai-unavailable", "ai-connection-failed", "articulate-bad-results",
    ]
}
#endif
