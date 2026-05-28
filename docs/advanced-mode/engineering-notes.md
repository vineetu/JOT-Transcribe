# Advanced mode — engineering notes

Companion to `design.md`. Holds the file-by-file implementation plan, storage-key contracts, migration sentinel logic, exhaustive risk register, and code-level pseudocode. The PM doc (`design.md`) is the source of truth for product intent; this doc is the source of truth for *how* it gets wired up.

---

## 1. Current state — cited

### 1.1 Sidebar layout (today)

Sidebar is built in `Sources/App/AppSidebar.swift` (not `Sources/MainWindow/` — that directory does not exist; the CLAUDE.md "MainWindow" entry refers to the architectural layer hosted under `Sources/App/`). Source-list order, taken from `AppSidebar.swift:28-123` (re-greped 2026-05-27 to fix earlier off-by-3 line citations):

1. **Home** — `Label("Home", systemImage: "house")` tagged `.home` (line 30-31).
2. **Settings** (DisclosureGroup, expanded by default) — header is a `Button` that routes to `.settings(.general)` and keeps the group expanded (line 99-110, the force-expand on line 101). Sub-rows in declared order:
   - General — `slider.horizontal.3` → `.settings(.general)` (line 34-38).
   - Transcription — `waveform.badge.mic` → `.settings(.transcription)` (line 39-43).
   - Speaker labels — `person.wave.2` → `.settings(.speakerLabels)`, **gated by `Features.speakerLabels`** (line 44-50). `Features.speakerLabels = false` in `Sources/App/Features.swift:19`, so this row is currently invisible.
   - Vocabulary — `text.book.closed` → `.settings(.vocabulary)`, gated to hide while the active primary is the JA model (line 57-63).
   - Prompts — `text.bubble` → `.settings(.prompts)` (line 64-68).
   - Sound — `speaker.wave.2` → `.settings(.sound)` (line 69-73).
   - AI — `sparkles` → `.settings(.ai)` (line 74-78).
   - Shortcuts — `command` → `.settings(.shortcuts)` (line 79-83).
3. **Help** — `questionmark.circle` → `.help` (line 113-114).
4. **Ask Jot** — `sparkles` → `.askJot`, label muted when Apple Intelligence is unavailable (line 116, askJotRow defined line 131-145).
5. **About** — `info.circle` → `.about` (line 118-119).

**There is no Donations sidebar entry.** Donations is reached as (a) a dismissible card on Home (`Sources/Home/HomePane.swift:30-33` → `DonationCard`) and (b) an About-pane section (`Sources/Settings/AboutPane.swift`). Both open `DonationsView` as a sheet, not a sidebar destination.

### 1.2 Selection enum

`Sources/App/AppSidebarSelection.swift` defines:

```
enum AppSidebarSelection: Hashable {
    case home
    case askJot
    case settings(SettingsSubsection)   // .general, .transcription, .vocabulary,
                                        // .prompts, .sound, .ai, .shortcuts, .speakerLabels
    case help
    case about
}
```

`JotAppWindow.swift:230-269` is the exhaustive `switch` that maps selection → pane. The selection is the single source of truth — sparkle icons, "Learn more →" popover footers, and the `ShowFeatureTool` cloud Ask Jot tool all mutate it through the `\.setSidebarSelection` environment closure or via `HelpNavigator.sidebarSelection`.

### 1.3 "Allow Ask Jot to use this provider" toggle

Lives in `Sources/Settings/RewritePane.swift:9, 89-95`:

```
@AppStorage("jot.askjot.allowCloud") private var allowCloudAskJot = false
…
if !isAppleIntelligenceSelected {
    Toggle("Allow Ask Jot to use this provider", isOn: $allowCloudAskJot)
    Text("Sends your Ask Jot conversation and Jot's help content to the selected provider using your API key.")
}
```

Read by `Sources/AskJot/HelpChatStore.swift:42, 198-206`:

```
private static let allowCloudPreferenceKey = "jot.askjot.allowCloud"
private static func isCloudAskJotEnabled(llmConfiguration: LLMConfiguration) -> Bool {
    let provider = llmConfiguration.provider
    return provider != .appleIntelligence &&
        UserDefaults.standard.bool(forKey: allowCloudPreferenceKey)
}
```

Call sites of `isCloudAskJotEnabled()` inside `HelpChatStore.swift`: lines 131, 158, 198, 204, 215, 259, 270, 279, 682. They all collapse to "is the configured provider non-Apple Intelligence?" once the gate is removed.

### 1.4 Speaker Labels card in TranscriptionPane

`Sources/Settings/TranscriptionPane.swift:37` calls `speakerLabelsCard` **unconditionally** inside `Form`. The card body (line 111-141) is a Section with a button that routes to `.settings(.speakerLabels)`. The sidebar entry for that selection is gated by `Features.speakerLabels = false`, but the card itself is not. Clicking the card today succeeds — `JotAppWindow.swift:251` still renders `SpeakerLabelsPane()` for `.speakerLabels`, you just can't get there from the sidebar.

### 1.5 Push-to-Talk shortcut row

`Sources/Settings/ShortcutsPane.swift:35, 40, 250` (single-key storage), and the row itself is added via `Sources/Settings/Shortcuts/ShortcutsRowModel.swift:112-121`:

```
case .pushToTalk:
    return ShortcutsRow(
        kind: .bindable(action),
        group: .recording,
        title: "Push to Talk",
        …
```

`ShortcutsRow.all` (line 167) is `SingleKey.Action.allCases.map(ShortcutsRow.forAction) + [.cancelRow]`. The five bindable rows are:

- Toggle Recording (Recording group)
- Push to Talk (Recording group)
- Paste Last Result (Recording group)
- Rewrite with Voice (Rewrite group)
- Rewrite (Rewrite group)
- + Cancel (Capture & Cancel group, read-only)

### 1.6 Vocabulary

`Sources/Vocabulary/VocabularyPane.swift` is the pane. It's the destination of:

- The sidebar Vocabulary row (`AppSidebar.swift:57`).
- Settings popover "Learn more →" deep-links into Help anchor `custom-vocabulary` (`HelpInfraTests.swift:469`, several popovers reference `helpAnchor: "custom-vocabulary"`).
- Ask Jot's `ShowFeatureTool` slug `custom-vocabulary` (`HelpChatStore.swift:804-805, 841-842`, `Help/Feature.swift:166, 229, 398`).
- The Help tab's Basics sub-row `custom-vocabulary` (`Help/Basics/BasicsContent.swift`).

The only `setSidebarSelection(.settings(.vocabulary))` call originates from the Vocab pane's own popover, which is hidden when Advanced is off.

### 1.7 Ask Jot surfaces

All of which need to disappear or no-op when Advanced is off:

- Sidebar row (`AppSidebar.swift:116`).
- About-pane "Ask Jot" section (`AboutPane.swift:213-247`).
- Help Basics sparkle icons that pre-fill and navigate to `.askJot` (`Help/HelpBasicsView.swift:144-162`).
- `HelpNavigator.sidebarSelection = .askJot` writes from `AskJotView` itself (line 525 — that's the Help-tab-back link inside Ask Jot, irrelevant when Ask Jot is hidden).

### 1.8 Home

`Sources/Home/` contains:
- `HomePane.swift` — top-level view; `RecordingsListView(navigationTitle: "Home")` at line 18.
- `BasicsBanner.swift` — first-run banner; uses `@AppStorage("jot.home.bannerDismissed")` (storage key referenced at line 19, doc comment line 12).

User-visible strings containing "Home":
- `AppSidebar.swift:30` — `Label("Home", systemImage: "house")`.
- `HomePane.swift:18` — `navigationTitle: "Home"`.
- `Localizable.xcstrings:991-994` — translation entry for "Home".
- `AskJot/HelpChatStore.swift:727` — Ask Jot grounding instruction: `ALWAYS use exact UI names: "Settings → AI", "Home", "Library".`

Internal symbols containing "home" / "Home":
- `AppSidebarSelection.home` (enum case, exhaustively switched in `JotAppWindow.swift:236`, `MenuBar/JotMenuBarController.swift:598, 606`, `AppDelegate.swift` indirect).
- `HomePane` (the struct, only referenced from `JotAppWindow.swift:237`).
- `BasicsBanner` (only used from `HomePane`).
- `MenuBar/JotMenuBarController.swift:411, 605` — `showRecordingsHome` selector for the "Show All Recordings…" menu item.
- `@AppStorage("jot.home.bannerDismissed")` (one storage key, must NOT change — already in users' UserDefaults).

### 1.9 FirstRunState

`Sources/App/FirstRunState.swift`:

```
@AppStorage("jot.setupComplete") var setupComplete: Bool = false
func markComplete() { setupComplete = true }
func reset() { UserDefaults.standard.removeObject(forKey: "jot.setupComplete"); … }
```

`SetupWizardCoordinator.swift:176` calls `FirstRunState.shared.markComplete()` at wizard completion. `Settings/ResetActions.swift:68` calls `.reset()` from the soft-reset / hard-reset paths.

---

## 2. Investigation findings

Things discovered while reading the code that shape the design:

- **The sidebar entry for `.speakerLabels` is already gated by `Features.speakerLabels = false`**, but the corresponding card in `TranscriptionPane.swift:37` is NOT gated. So `Features.speakerLabels` is currently a half-applied gate. Fix is one line of code: wrap the `speakerLabelsCard` call in `if Features.speakerLabels { speakerLabelsCard }`. The Advanced-mode question is orthogonal: even WITH Advanced on, the card shouldn't render while `Features.speakerLabels = false`.

- **`AppSidebarSelection` is an enum exhaustively switched in `JotAppWindow.detail`** (line 234-269). That's CLAUDE.md's "compiler is the checklist" pattern. Two implementation choices for Advanced gating:
  - (a) Keep the enum cases the same and just hide rows in the sidebar; the `detail` switch still has cases for the hidden selections (they remain reachable if someone writes the enum value directly).
  - (b) Add a redirect/sanitize layer at the boundary so any "now-hidden" selection bounces to a visible one.

  We need (b). Without it, a user who had `pendingSelection = .askJot` from a previous launch (e.g. from the About-pane "Ask Jot" Section button at `AboutPane.swift:217`) will land in a pane that doesn't exist on the sidebar — confusing. Sparkle icons in Help (`Help/HelpBasicsView.swift:162`) are the same shape. Pattern: at every site that mutates `selection`, the source row that mutates it must also disappear. We're solving "hide the entry point" rather than "block at the boundary."

- **`NavigationHistory` (line 32 of `JotAppWindow`) tracks sidebar selection changes for the back/forward buttons.** If a user toggles Advanced off while sitting on `.askJot`, the history may have stale entries pointing at `.askJot`. We scrub the history (filter, not clear) when Advanced is flipped off.

- **`JotAppWindow.pendingSelection` is set by the menu bar before opening the window (line 30, 107).** Read once as initial state. The menu bar today doesn't write `.askJot` (it writes `.home` from `showRecordingsHome` only), so this is a latent risk for future menu items, not a current bug.

- **The `HelpNavigator.sidebarSelection` observer at `JotAppWindow.swift:172-176` mirrors navigator-driven changes into the bound selection.** That's the route the Ask Jot sparkle icons take. If we hide the sparkle entry points, this path doesn't fire — but the observer itself stays, so no compile change needed.

- **The Vocabulary pane has a "Learn more →" popover that deep-links into the Help tab anchor `custom-vocabulary`.** When Advanced is off and the user is in the Help tab reading about Custom Vocabulary, the in-Help anchor still resolves (it's a Help-tab anchor, not a Settings-pane anchor). So Help → Custom Vocabulary section is fine. The popover that *originates* a deep-link FROM Vocabulary is the one that disappears with the Vocabulary pane.

- **Renaming `HomePane` → `RecentsPane` is mostly mechanical**, but: the `@AppStorage("jot.home.bannerDismissed")` key must NOT change. And `AppSidebarSelection.home` is referenced from `JotAppWindow.swift:107, 236`, `MenuBar/JotMenuBarController.swift:598, 605, 606`, and `JotMenuBarController.swift:411` selector name. Renaming the enum case is a churn cost (see options below).

- **Ask Jot's grounding doc (`Resources/help-content.md`) mentions "Home"** in line 727 of `HelpChatStore.swift`. The 1500-token budget check (`tools/check-help-doc-budget.swift`) is enforced at build, so any grounding edit needs to fit. Current baseline: 1015 tokens.

- **Apple Intelligence is enabled by default for fresh installs on macOS 26+** (CLAUDE.md). A fresh install on macOS 26+ with Advanced=off has Ask Jot hidden AND Apple Intelligence as the default provider. When they later flip Advanced on, Ask Jot appears already pointed at Apple Intelligence.

---

## 3. Options explored

### 3.1 Rename `Sources/Home/` → `Sources/Recents/` vs strings-only

**Option A — Strings-only rename.** Change `Label("Home", …)` → `Label("Recents", …)`, `navigationTitle: "Home"` → `"Recents"`, and the one Ask Jot grounding-string mention. Leave `HomePane`, `BasicsBanner`, `AppSidebarSelection.home`, `Sources/Home/`, `jot.home.bannerDismissed`, `showRecordingsHome` selector as-is.

- Pros: Minimal diff. No risk of breaking source-list anchor IDs in `JotAppWindow`. No churn on `MenuBar/JotMenuBarController.swift` selector names. `@AppStorage` key stays the same.
- Cons: Internal-name vs user-visible-name drift.

**Option B — Full rename.** Rename `HomePane` → `RecentsPane`, `Sources/Home/` → `Sources/Recents/`, `AppSidebarSelection.home` → `.recents`, selector `showRecordingsHome` → `showRecents`. Leave `@AppStorage` keys alone.

- Pros: Internal names match user-facing names.
- Cons: Bigger diff. Touches at least 8 files. The internal symbol `home` is referenced via Objective-C selector strings — stringly-typed and not caught by the Swift compiler if you miss one.

**Selected: Option A (strings-only).** Internal-symbol rename filed as future debt at `docs/advanced-mode/rename-internal-symbols-deferred.md`.

### 3.2 Sidebar layout — flat vs nested

**Option F1 — Flatten everything.** Top-level entries: Recents, General, Shortcuts, AI, Prompts, Help, About. Under Advanced: + Vocabulary, + Ask Jot, + Transcription, + Sound.

**Option F2 — Keep nesting, just hide the gated sub-rows.** Sidebar stays Recents / Settings (DisclosureGroup with sub-rows) / Help / Ask Jot / About. With Advanced off, the DisclosureGroup loses Vocabulary; AskJot row hides; Speaker Labels stays hidden.

**Option F3 — Hybrid: flatten the panes the owner named, nest the rest under "Settings > Advanced".** Rejected — Transcription/Sound aren't "advanced."

**Selected: Option F2.** Confirmed by owner 2026-05-27. F2 → F1 later is mechanical; F1 → F2 later is harder.

### 3.3 Speaker Labels card gating

**Option S1 — Hide unconditionally.** Wrap the card in `if Features.speakerLabels { speakerLabelsCard }`. Mirrors the sidebar's existing gate. One line.

**Option S2 — Gate behind both `Features.speakerLabels` AND `advancedEnabled`.**

**Selected: Option S1.** Don't stack `Features.speakerLabels && advancedEnabled` post-ship. `Features.swift:3-10` documents `Features.speakerLabels` as a single-flip kill switch. At the moment Speaker Labels actually ships, `Features.speakerLabels` becomes vestigial (always-true and removable), and the gate should be purely `advancedEnabled`.

### 3.4 Where the Advanced toggle lives

Settings → General, last Section. Existing sections in `GeneralPane.swift` are Input device, Login/Dock, Retention, Troubleshooting, Reset, Reminders. New Section between "Reminders" and the end, titled "Advanced" with one toggle ("Show advanced features") and a one-line subtitle.

Bottom placement is the iOS Settings convention. Top placement was rejected — beginners shouldn't see "Advanced" as the second thing on the page.

### 3.5 Advanced-toggle discoverability for new users

**Option D1 — `BasicsBanner` line on Home/Recents.** Add a line to the first-run banner: "Looking for more? Settings → General → Advanced."

**Option D2 — Persistent hint card on the Recents pane.**

**Option D3 — Help Basics intro line.**

**Selected: Option D1.** Implementation hook: `Sources/Home/BasicsBanner.swift` — add a footer line:
```
"More options — custom vocabulary, Ask Jot chatbot, push-to-talk — live
 behind 'Advanced' in Settings → General."
```

### 3.6 Collapsible Settings sub-panes

#### Current state (cited)

`Sources/App/AppSidebar.swift:26` declares the expanded state as transient `@State`:

```
@State private var settingsExpanded: Bool = true
```

The `DisclosureGroup` is already bound to it (line 33: `DisclosureGroup(isExpanded: $settingsExpanded)`), so the chevron-driven collapse mechanism is *already wired* — but two things break the user-facing "collapsible" promise:

1. **State is not persisted.** Every fresh view materialization re-initializes `settingsExpanded = true`.
2. **The header `Button` force-expands on click** (`AppSidebar.swift:99-101`):
   ```
   Button {
       selection = .settings(.general)
       settingsExpanded = true     // <— force-expand on any header click
   } label: { … }
   ```

#### Options

**Option C1 — Continue with `DisclosureGroup`, persist via `@AppStorage`.** Swap `@State private var settingsExpanded` for `@AppStorage("jot.sidebar.settingsExpanded") private var settingsExpanded: Bool = true`. Stop the force-expand inside the header `Button`.

**Option C2 — Replace `DisclosureGroup` with a `Section` plus custom chevron.**

**Option C3 — Keep `DisclosureGroup` but make the header itself toggle on click.** Conflicts with macOS 26.4 sidebar idiom doc comment at `AppSidebar.swift:84-98`.

**Selected: Option C1.** Default expanded for both new and existing users. Persistence key `jot.sidebar.settingsExpanded` follows project convention.

#### Header click behavior change

After this change:
- Clicking the header still navigates to General.
- Clicking the header does NOT force-expand. If the user has collapsed the group, clicking "Settings" navigates to General without expanding.

Smoke item: after shipping, observe whether real users get confused by the navigate-only-on-header behavior.

#### Pseudocode

```
struct AppSidebar: View {
    @Binding var selection: AppSidebarSelection
    let askJotAvailable: Bool
    @EnvironmentObject private var transcriberHolder: TranscriberHolder

    // BEFORE: @State private var settingsExpanded: Bool = true
    // AFTER:  persisted across relaunches, default expanded.
    @AppStorage("jot.sidebar.settingsExpanded") private var settingsExpanded: Bool = true

    var body: some View {
        List(selection: $selection) {
            Label("Recents", systemImage: "house").tag(.home)

            DisclosureGroup(isExpanded: $settingsExpanded) {
                // unchanged sub-rows: General / Transcription / Vocabulary
                // (gated) / Prompts / Sound / AI / Shortcuts
            } label: {
                Button {
                    selection = .settings(.general)
                    // REMOVED: settingsExpanded = true
                } label: {
                    HStack(spacing: 0) {
                        Label("Settings", systemImage: "gearshape")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Settings at General.")
            }

            Label("Help", systemImage: "questionmark.circle").tag(.help)
            askJotRow
            Label("About", systemImage: "info.circle").tag(.about)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }
}
```

#### Selection state preservation across collapse

`DisclosureGroup` collapse hides the sub-row views but does NOT change `selection`. Re-expanding restores the sub-row with the selection highlight intact. No code needed.

---

## 4. Storage keys

| Key | Type | Default | Purpose |
|---|---|---|---|
| `jot.advanced.enabled` | Bool | `false` | Master toggle. Migration writes `true` for existing users. |
| `jot.advanced.migrated` | Bool | `false` | One-shot migration sentinel. |
| `jot.sidebar.settingsExpanded` | Bool | `true` | Persisted DisclosureGroup state. |
| `jot.askjot.allowCloud` | Bool | (legacy) | Read-only migration sentinel; preserves explicit-false opt-out. |
| `jot.askjot.providerMigrationBannerSeen` | Bool | `false` | Tracks first-open banner dismissal. |
| `jot.setupComplete` | Bool | `false` | (existing) Used as existing-user signal. |
| `jot.home.bannerDismissed` | Bool | `false` | (existing) Must NOT change despite Home→Recents rename. |

---

## 5. Migration plan

### 5.1 One-shot migration on launch + wizard auto-flip

Two distinct writes to `jot.advanced.enabled`:

**(a) One-shot migration on launch.** Run inside `AppDelegate.applicationDidFinishLaunching(_:)`, **before** any SwiftUI window materializes:

```
private static let advancedKey = "jot.advanced.enabled"
private static let advancedMigratedKey = "jot.advanced.migrated"

func migrateAdvancedFlagIfNeeded() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: advancedMigratedKey) else { return }
    let wasSetupComplete = defaults.bool(forKey: "jot.setupComplete")
    // existing user (wizard already done) → preserve current surface (advanced ON)
    // fresh install (wizard not yet run) → streamlined surface (advanced OFF)
    defaults.set(wasSetupComplete, forKey: advancedKey)
    defaults.set(true, forKey: advancedMigratedKey)
}
```

The sentinel (`jot.advanced.migrated`) makes the migration idempotent — write-once. Without it, if the user toggles Advanced off and quits, the next launch would overwrite their choice back to `true`.

**(b) Wizard auto-flip.** `SetupWizardCoordinator.swift:176` calls `FirstRunState.shared.markComplete()` at wizard completion. With the new product rule, that callsite must also write `jot.advanced.enabled = true` atomically. The wizard introduces Custom Vocabulary, AI features, and Prompts — hiding them after the user has been walked through them would be a UX contradiction.

Pseudocode for `FirstRunState.markComplete()` (in `Sources/App/FirstRunState.swift`):

```
func markComplete() {
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: "jot.setupComplete")
    defaults.set(true, forKey: AdvancedFlag.storageKey)  // jot.advanced.enabled
    // (migrated sentinel may already be true from launch migration; leave as-is)
    setupComplete = true
}
```

Both writes hit `UserDefaults` directly so they're observed by any `@AppStorage` binding immediately. The `setupComplete = true` assignment after the explicit writes keeps the `@AppStorage`-backed property in sync.

**Trace through all scenarios:**

| Scenario | Boot state | Migration writes | Wizard outcome | Final state |
|---|---|---|---|---|
| Fresh install boot | `setupComplete=false` | `advanced=false`, `migrated=true` | Wizard presented | `advanced=false`, awaiting wizard |
| Fresh install, completes wizard | (above) | (above) | `markComplete()` writes `setupComplete=true` AND `advanced=true` | `advanced=true`, slim mode never seen again |
| Fresh install, Cmd+Q mid-wizard | (above) | (above) | No `markComplete()` call | `advanced=false`, `setupComplete=false`. Slim mode. Wizard re-runs on next launch, or user can manually flip Advanced. |
| Existing user upgrade | `setupComplete=true` (already) | `advanced=true`, `migrated=true` | No wizard interaction | `advanced=true`. Unchanged from yesterday. |
| Existing user who never finished wizard | `setupComplete=false` | `advanced=false`, `migrated=true` | Wizard re-presented; if completed, both keys flip. | Slim mode until wizard completes or manual flip. |

**Signal reliability — verified.** `git log --diff-filter=A -- Sources/App/FirstRunState.swift` shows `setupComplete` was added 2026-04-15 in commit `1ed076b`. Custom Vocabulary shipped 2026-04-21 (commit `f48e9fa`, v1.6), Ask Jot shipped later (the redesign in `e09678e` postdates v1.6), Push-to-Talk was wired in `48f1d7d` — also after `setupComplete`. **Every gated feature postdates the `setupComplete` signal.** Signal is sound for the entire installed base.

### 5.2 Ask Jot allow-cloud — one-way migration preservation

Delete the UI control. `HelpChatStore.isCloudAskJotEnabled` becomes:

```
private static func isCloudAskJotEnabled(llmConfiguration: LLMConfiguration) -> Bool {
    let provider = llmConfiguration.provider
    guard provider != .appleIntelligence else { return false }
    // Migration: if a v1.x user explicitly set the (now-removed) toggle
    // to false, preserve that opt-out forever. Fresh installs and users
    // who had it set to true follow the global provider.
    let defaults = UserDefaults.standard
    if defaults.object(forKey: allowCloudPreferenceKey) != nil
       && defaults.bool(forKey: allowCloudPreferenceKey) == false {
        return false
    }
    return true
}
```

Note: `UserDefaults.object(forKey:) != nil` is the key check — "value is explicitly false" vs "key is absent" are different states and the test cannot use `bool(forKey:)` alone (which returns `false` for both).

### 5.3 Off → On → Off behavior (data preserved)

When the user flips Advanced off:
- All `@AppStorage` keys for the gated features remain on disk (Vocabulary file, `jot.askjot.allowCloud` — although that key is no longer read by the UI, it persists), shortcut bindings persist.
- UI is hidden, but the pipelines stay compiled and reachable. This mirrors `Features.speakerLabels`'s contract.
- A user who had bound a chord to Push-to-Talk will see the row vanish but the binding remains registered with `KeyboardShortcuts`. The hotkey **continues to fire** (we do not unregister bindings on Advanced=off).

### 5.4 Reset behavior

`Settings/ResetActions.swift` has soft / hard reset paths. Both reset `FirstRunState.shared.reset()` → `jot.setupComplete = false`. Both should additionally reset `jot.advanced.enabled` and `jot.advanced.migrated`.

For `jot.sidebar.settingsExpanded`: remove on hard reset, preserve on soft reset (debatable — see open question §8 #7).

### 5.5 Edge cases

- **User on restored prefs (Migration Assistant from old Mac):** `jot.setupComplete = true` migrated in, they get Advanced=true. Correct.
- **User on a fresh laptop installing Jot from scratch:** `jot.setupComplete = false` on first launch, migration sets Advanced=false. Setup wizard runs, sets `setupComplete = true`. Advanced stays false. Correct.
- **User who used Jot earlier this year but never completed Setup Wizard:** `jot.setupComplete = false` despite being an "existing user" by some other metric. Migration lands them on Advanced=false. Treated as a new install. Edge case is small.
- **Multi-mac sync via iCloud Keychain:** Jot doesn't sync preferences. Each Mac migrates independently — fine.

---

## 6. Implementation plan (phased)

### Phase 1 — Migration + toggle wiring + Setup Wizard copy

0. **`Sources/SetupWizard/Steps/DoneStep.swift:73-75`** — the "Advanced, for later" card currently names hidden-by-default features. Rewrite to point at the Advanced toggle:
   ```
   Title:    "Advanced, for later"
   Body:     "More power-user options — including LLM cleanup, voice-driven
              rewrite, and custom vocabulary — live behind the Advanced toggle
              in Settings → General. Flip it on whenever you're curious; flip
              it off again to keep the surface minimal."
   ```

   **Also scan `Sources/SetupWizard/Steps/ModelStep.swift:104, 108`** — the optional Vocabulary-boost download offers the model "Needed only if you plan to use Settings → Vocabulary." Rewrite as:
   ```
   "Needed only if you plan to use Jot's Custom Vocabulary feature.
    Custom Vocabulary lives behind the Advanced toggle in Settings →
    General; you can download this model later from there."
   ```

1. **`Sources/App/FirstRunState.swift` or new `Sources/App/AdvancedFlag.swift`** — add `AdvancedFlag` namespace:
   ```
   enum AdvancedFlag {
       static let storageKey = "jot.advanced.enabled"
       static let migratedKey = "jot.advanced.migrated"
       static func migrateIfNeeded(defaults: UserDefaults = .standard) {
           guard !defaults.bool(forKey: migratedKey) else { return }
           let existingUser = defaults.bool(forKey: "jot.setupComplete")
           defaults.set(existingUser, forKey: storageKey)
           defaults.set(true, forKey: migratedKey)
       }
   }
   ```

1b. **`Sources/App/FirstRunState.swift` — wizard auto-flip wiring.** Update `markComplete()` to write both keys atomically:
   ```
   func markComplete() {
       let defaults = UserDefaults.standard
       defaults.set(true, forKey: "jot.setupComplete")
       defaults.set(true, forKey: AdvancedFlag.storageKey)
       setupComplete = true
   }
   ```
   `SetupWizardCoordinator.swift:176` already calls `FirstRunState.shared.markComplete()` at wizard completion — no change needed at the callsite; the wiring lives inside `markComplete()`. See §5.1(b) for the trace through all scenarios.

2. **`Sources/App/AppDelegate.swift`** — call `AdvancedFlag.migrateIfNeeded()` at the top of `applicationDidFinishLaunching`, before NSApp policy or services graph construction.

3. **`Sources/Settings/GeneralPane.swift`** — add `@AppStorage("jot.advanced.enabled") private var advancedEnabled: Bool = false`. Append a new Section at the bottom:
   ```
   Section("Advanced") {
       Toggle("Show advanced features", isOn: $advancedEnabled)
       Text("Custom vocabulary, Ask Jot chatbot, push-to-talk, and other power-user options.")
           .font(.caption).foregroundStyle(.secondary)
   }
   ```

4. **`Sources/Settings/ResetActions.swift`** — soft + hard reset paths additionally remove `jot.advanced.enabled` and `jot.advanced.migrated`.

### Phase 2 — Gate the four features

5. **`Sources/App/AppSidebar.swift`** — accept new param `advancedEnabled: Bool` from `JotAppWindow`. Inside the body:
   - Vocabulary sub-row: wrap existing `if transcriberHolder.primaryModelID != .tdt_0_6b_ja` in additional `if advancedEnabled && …`.
   - Ask Jot row: wrap `askJotRow` in `if advancedEnabled { askJotRow }`.
   - **Collapsible Settings group:** swap `@State private var settingsExpanded: Bool = true` for `@AppStorage("jot.sidebar.settingsExpanded") private var settingsExpanded: Bool = true`. Remove the `settingsExpanded = true` line inside the header `Button` closure (line 101).

6. **`Sources/App/JotAppWindow.swift`** — three changes, all in one file:

   (a) **Add a `sanitize` static helper:**
   ```
   private static func sanitize(_ raw: AppSidebarSelection, advancedEnabled: Bool) -> AppSidebarSelection {
       guard !advancedEnabled else { return raw }
       switch raw {
       case .askJot, .settings(.vocabulary):
           return .home   // .recents post-rename
       default:
           return raw
       }
   }
   ```

   (b) **Wrap the `\.setSidebarSelection` environment closure with `sanitize`** (line 146-148):
   ```
   .environment(\.setSidebarSelection) { newValue in
       selection = JotAppWindow.sanitize(newValue, advancedEnabled: advancedEnabled)
   }
   ```

   (c) **Sanitize `pendingSelection` at init** (line 107):
   ```
   let raw = JotAppWindow.pendingSelection ?? .home
   let advancedEnabled = UserDefaults.standard.bool(forKey: AdvancedFlag.storageKey)
   let initial = JotAppWindow.sanitize(raw, advancedEnabled: advancedEnabled)
   ```

   (d) **Read the flag, pass to `AppSidebar`. Add an `.onChange(of: advancedEnabled)` observer:**
   ```
   .onChange(of: advancedEnabled) { _, isOn in
       if !isOn {
           // 1. Redirect current selection.
           selection = JotAppWindow.sanitize(selection, advancedEnabled: false)

           // 2. Cancel any in-flight Ask Jot stream.
           chatStore.cancelStream()

           // 3. Filter stale back-history entries pointing at now-hidden panes.
           navHistory.filter { sel in
               sanitize(sel, advancedEnabled: false) == sel
           }
       }
   }
   ```

7. **`Sources/Settings/TranscriptionPane.swift`** — change `speakerLabelsCard` callsite at line 37 to `if Features.speakerLabels { speakerLabelsCard }`. (Decoupled from Advanced.)

8. **`Sources/Settings/AboutPane.swift`** — wrap `askJotSection` call (line 63) in `if advancedEnabled { askJotSection }`. Read flag via `@AppStorage` in AboutPane.

9. **`Sources/Help/HelpBasicsView.swift`** — gate the sparkle-icon affordances (line 144-162) behind `advancedEnabled`. Read flag via `@AppStorage`.

10. **`Sources/Settings/Shortcuts/ShortcutsRowModel.swift`** — add an `isAdvanced: Bool` property to `ShortcutsRow`. Push-to-Talk row marked `isAdvanced: true`. (Paste Last Result: marked `isAdvanced: true` per assumption; owner override may flip to false.)

11. **`Sources/Settings/ShortcutsPane.swift`** — read `@AppStorage("jot.advanced.enabled")`. When building `ShortcutsRow.all` or before passing to `ShortcutsSearchFilter.filter`, drop rows where `isAdvanced == true && !advancedEnabled`. Apply the same filter in `groupedRows`, `searchResults`, and `conflictMessage`.

11b. **`Sources/App/NavigationHistory.swift`** — add a `filter` API. Current public surface has no clear/filter API — `back` is `private(set)`. Add:
   ```
   /// Drops back/forward entries that no longer satisfy `predicate`.
   /// Preserves the relative order of survivors.
   func filter(_ predicate: (AppSidebarSelection) -> Bool) {
       back.removeAll { !predicate($0) }
       forward.removeAll { !predicate($0) }
   }
   ```

12. **AskJot allow-cloud toggle removal (with one-way migration preservation):**

    (a) **`Sources/Settings/RewritePane.swift`** — remove lines 9, 89-95 (the `@AppStorage` declaration and the Toggle + caption text inside the `if !isAppleIntelligenceSelected` block).

    (b) **`Sources/AskJot/HelpChatStore.swift`** — keep `allowCloudPreferenceKey` (line 42) — it's still read for migration. Rewrite `isCloudAskJotEnabled` per §5.2. Update the doc comment block (lines 265-279) to explain the migration.

    (c) **First-open banner for upgrading users on a cloud provider** — `Sources/AskJot/AskJotView.swift` shows a one-time dismissible banner on first Ask Jot open when (i) `llmConfiguration.provider != .appleIntelligence` AND (ii) `UserDefaults` has the `allowCloud` key set to `true`. Banner text:
    ```
    "Ask Jot now uses your configured AI provider directly. To keep
     Ask Jot on Apple Intelligence, switch Settings → AI → Provider."
    ```
    Dismissal stored in `@AppStorage("jot.askjot.providerMigrationBannerSeen") = false`.

**Phase 2 + Phase 3 ship together, not sequentially.** Phase 2 hides Ask Jot for Advanced=off users; Phase 3 updates the Ask Jot grounding instruction to say "Recents" instead of "Home". If Phase 2 ships first, an Advanced=on user opens Ask Jot and the chatbot tells them to "click Home" while the sidebar says "Recents" — the grounding is now lying. If Phase 3 ships first, the rename leaks before the gating is in place. Treat them as one atomic release.

### Phase 3 — Rename Home → Recents (strings-only)

13. **`Sources/App/AppSidebar.swift:30`** — `Label("Home", systemImage: "house")` → `Label("Recents", systemImage: "house")`. (SF Symbol stays `house` — owner can override later.)

14. **`Sources/Home/HomePane.swift:18`** — `RecordingsListView(navigationTitle: "Home")` → `navigationTitle: "Recents"`.

15. **`Resources/Localizable.xcstrings:991-994` — orphan housekeeping (optional).** SwiftUI `Label(_ titleKey: LocalizedStringKey, …)` resolves "Home" via the xcstrings catalog at runtime. After this change, the Swift source says `Label("Recents", …)`, so SwiftUI looks up the key `"Recents"`; that key is absent, so SwiftUI falls back to the literal "Recents". Outcome regardless of xcstrings: the UI shows "Recents" at runtime. Per CLAUDE.md (Jot is English-only), the practical impact of leaving the orphaned "Home" entry is zero.

16. **`Sources/AskJot/HelpChatStore.swift:727`** — update grounding string:
    ```
    ALWAYS use exact UI names: "Settings → AI", "Recents", "Library".
    ```
    Verify the help-content budget check (`tools/check-help-doc-budget.swift`) still passes — replacing "Home" with "Recents" adds ~1 token; well within the 1500-token budget (currently at 1015 tokens).

17. **`Sources/MenuBar/JotMenuBarController.swift:411`** — the menu item's localized title `Show All Recordings…` already says "Recordings" not "Home", so no string change. The selector `showRecordingsHome` is internal — leave it.

17b. **`Resources/help-content-base.md` + `Resources/fragments/*.md` scan.** Verified: `grep -i "home" Resources/help-content-base.md Resources/fragments/*.md` returns only one match — `help-content-base.md:47` mentions "Library items" (different concept). No fragment references the "Home" sidebar UI name. After both edits land, run `tools/check-help-doc-budget.swift` to confirm budget.

17c. **Ask Jot citation-coverage smoke test.** CLAUDE.md flags current shipped citation coverage as ~61%. Sharp-fix leak coverage is 100%. Renaming "Home" → "Recents" shouldn't change citation behavior. Smoke item, not a blocker.

18. **CLAUDE.md update** — bullet under "When you ship a feature, update these": this section, `docs/features.md`, README, website.

### Phase 4 — Tests

19. **DEBUG-only `AdvancedFlagTests.swift`** — pure-function tests for `AdvancedFlag.migrateIfNeeded`:
    - fresh defaults → `advancedEnabled == false`, `migrated == true`.
    - `setupComplete == true` + clean migrated key → `advancedEnabled == true`, `migrated == true`.
    - second call is a no-op (verify with intervening `defaults.set(false, forKey: advancedKey)`).
    Patterned after `DockActivationPolicyTests.swift`. Call from `applicationDidFinishLaunching`'s `#if DEBUG` block.

20. **`HelpInfraTests.runAll()`** — re-run the existing `InfoCircleAnchorTests` to confirm no deep-link anchor regressed.

21. **Manual smoke matrix** — covered in §7.

---

## 7. Risk register

### R1 — Sidebar selection on a now-hidden pane

Scenario: User has Advanced=on. They're sitting on the Ask Jot pane. They open Settings → General and flip Advanced off. Detail view is now `AskJotView()` but the sidebar no longer has that row.

**Mitigation:** the `.onChange(of: advancedEnabled)` observer in `JotAppWindow` (Phase 2 item 6) redirects `.askJot` and `.settings(.vocabulary)` to `.home`/`.recents` immediately. Also filter `navHistory` so back-button doesn't take them back to a hidden pane.

**Edge case:** `selection` is a `@State` in `JotAppWindow`; mutating it from inside `.onChange` should work in SwiftUI 7 / macOS 26.4. Verify in smoke test. If it doesn't, fall back to `DispatchQueue.main.async`.

### R2 — Help Basics "Open in Settings →" deep-links bypass the Advanced gate

Scenario: Advanced=off. User is in Help → Basics, expands the "Custom vocabulary" sub-row, and clicks the "Open in Settings →" button.

- `Sources/Help/Basics/SubRowList.swift:277-291` renders an `if let settingsLink = detail.settingsLink { Button { … setSidebarSelection(.settings(settingsLink.pane)) … } }` inside every expanded sub-row.
- `Sources/Help/Basics/BasicsContent.swift:260-273` defines a `SettingsLink(label: "Open in Settings", pane: .vocabulary, anchor: "custom-vocabulary")` on the `custom-vocabulary` sub-row.

**Mitigation:** introduce the `sanitize` redirect at the `\.setSidebarSelection` environment-closure level. This catches everything that goes through the environment closure: Basics "Open in Settings →" button, sparkle icons in `HelpBasicsView`, AboutPane "Ask Jot" section button, cloud `ShowFeatureTool`, and any future call site.

**Side benefit:** also covers the post-`scrollTo` no-op case — if the Help Basics sub-row's deep-link tries to scroll to a `pendingSettingsFieldAnchor` ("custom-vocabulary") inside a now-redirected Home pane, the scrollTo silently fails on a missing anchor — safe degradation.

### R3 — Help-content prose mentions hidden features

Current state: Help cards don't navigate to Settings — they're prose. The risk is only "user reads about feature, can't find it." Mitigation: Advanced toggle is one click away. Acceptable.

### R4 — Ask Jot grounding mentions Vocabulary / PTT

The chatbot grounding doc references both. With Advanced=off, Ask Jot is HIDDEN. So this risk only materializes when Advanced is on, at which point all features are visible. No conflict.

### R5 — PTT binding still fires when row is hidden

Scenario: User has bound `pushToTalk` to ⌥Space. They flip Advanced off. Their hotkey still fires. They can't see the row in Settings to unbind it.

**Mitigation:** Recommendation in §5.3 — leave the binding active. To unbind, the user re-enables Advanced.

### R6 — AskJot routing breakage from removing the cloud-opt-in toggle

Three sub-scenarios:

- **Stored `allowCloud == true`:** Today Ask Jot routes to OpenAI. After change: still routes to OpenAI. First-open banner appears once.
- **Stored `allowCloud == false`:** Today Ask Jot routes to Apple Intelligence. After change: **still routes to Apple Intelligence** — `isCloudAskJotEnabled` checks the explicit-false sentinel. They lose the UI control to flip it back on, but privacy boundary is preserved.
- **No `allowCloud` key set:** The key is absent and our migration treats the user as "fresh." Ask Jot starts using their cloud provider. Magnitude: likely small (RewritePane is where they entered their API key). First-open banner catches them.

### R7 — Migration race: `jot.advanced.enabled` read before `migrateIfNeeded` runs

`@AppStorage` is backed by `UserDefaults` KVO. Writes from any code path (including `defaults.set` in the migration) trigger an update. SwiftUI should pick it up on the next render.

**Mitigation:** Call `AdvancedFlag.migrateIfNeeded()` at the very top of `applicationDidFinishLaunching`, BEFORE the `services` graph is constructed and BEFORE `NSApp.setActivationPolicy`. Same pattern as `ResetActions.processPendingHardReset()` (line 122).

### R8 — Existing-user detection edge cases

Covered in §5.5.

### R9 — `NavigationHistory` has stale references

Mitigation: §6 item 11b adds the `filter` method; §6 item 6(d) calls it.

### R10 — Menu bar "Open Jot" routes to `.home`; no conflict

`JotMenuBarController.swift:598, 606` writes `.home`. Always visible. No conflict.

### R11 — Future menu items / notifications that route to `.askJot`

If a future contributor adds an "Open Ask Jot…" menu bar item that writes `JotAppWindow.pendingSelection = .askJot`, or posts a `.jotWindowSetSidebarSelection` notification (`JotAppWindow.swift:158-162`) with `.askJot`, and the user has Advanced=off, the window opens with `.askJot` selected but no sidebar row.

**Mitigation:** sanitize at three call sites:
- `\.setSidebarSelection` environment closure.
- `pendingSelection` read inside `JotAppWindow.init`.
- `.onChange(of: advancedEnabled)` observer.

Recommended for completeness: also sanitize the `.onReceive(.jotWindowSetSidebarSelection)` handler.

### R11b — In-flight Ask Jot stream when Advanced is flipped off

Scenario: User is mid-stream in Ask Jot. They Cmd+, to Settings → flip Advanced off. The selection redirects to Home, the sidebar Ask Jot row disappears, but `lastStreamTask` (`HelpChatStore.swift:62`) continues running and writing chunks.

**Mitigation:** §6 item 6(d) calls `chatStore.cancelStream()` inside the `.onChange(of: advancedEnabled)` flip-off observer. The method exists at `HelpChatStore.swift:663`.

### R12 — Sandboxed-defaults / DerivedData test isolation

Not relevant — no schema migrations, no SwiftData touches.

### R13 — Strings-only Home rename leaves the `case .home` enum visible in stack traces

Logs that print `selection` will show "home" not "recents". Cost: low — internal logs aren't user-visible.

### R14 — Xcode synchronized folder cache for `Sources/Home/`

`Sources/` is a `PBXFileSystemSynchronizedRootGroup`. **Resources/, however, is not** (per MEMORY). We're not adding any Resources files. Safe.

### R15 — Collapsing Settings while the active selection is a Settings sub-pane

Scenario: User is on `.settings(.ai)`. They click the chevron to collapse the sub-rows.

**Analysis:**
- `DisclosureGroup` collapse only affects the rendered sub-row views. `List(selection: $selection)` binding still holds `.settings(.ai)`.
- The detail-column `switch` continues to render `AISettingsPane()`.
- When the user re-expands, the AI sub-row materializes with its `.tag(.settings(.ai))` matching the bound selection.

**Outcome:** correct without code changes. Smoke test required on macOS 26.4.

### R16 — Keyboard focus traversal across a collapsed group

SwiftUI `List` + `DisclosureGroup` default behavior is: collapsed sub-rows are excluded from focus traversal. `↓` from Recents lands on the Settings header; another `↓` jumps to Help.

Verify in smoke test. Also check `←` / `→` on a focused Settings header.

### R17 — `@AppStorage` initial-read race in `AppSidebar`

`@AppStorage` returns the wrapped declared default when the key is absent. The first read returns `true`. The first write creates the key. No mitigation needed.

---

## 8. Open questions for the owner

🟡 **blocking** — block landing the feature until answered.
⚪ **non-blocking** — pick a default and ship.

**Resolved:**
- Sidebar layout — F2 (keep Settings nested) confirmed by owner 2026-05-27.
- Existing-user signal robustness — verified `jot.setupComplete` predates Vocabulary, Ask Jot, and Push-to-Talk.
- `jot.askjot.allowCloud` migration policy — preserve explicit-false as a one-way opt-out.

1. ⚪ **Paste Last Result shortcut row visibility.** Recommendation: hide when Advanced is off.
2. ⚪ **PTT/other-hotkey behavior when row is hidden.** Recommendation: hotkey binding stays registered.
3. ⚪ **"Advanced" wording.** Recommendation: "Show advanced features" with subtitle.
4. ⚪ **Speaker Labels card gating after `Features.speakerLabels` flips on.** Recommendation: retire the kill switch; gate on `advancedEnabled` alone.
5. ⚪ **Internal-symbol Home → Recents rename.** Recommendation: defer.
6. ⚪ **SF Symbol for "Recents".** Recommendation: keep `house`.
7. ⚪ **Reset behavior for `jot.sidebar.settingsExpanded`.** Recommendation: remove on hard reset, preserve on soft reset.
8. ⚪ **Settings header click — navigate-only vs navigate + force-expand.** Recommendation: navigate-only (decoupled).
9. ⚪ **Advanced toggle discoverability mechanism.** Recommendation: Option D1.
10. ⚪ **xcstrings cleanup for orphan "Home" entry.** Recommendation: leave or remove; behavior identical.

---

## 8.5 Success criteria (engineering view)

Mirrors §"Success criteria" in `design.md`, split between wizard-completed and wizard-quit scenarios.

**Fresh install, user quits the Setup Wizard early (Cmd+Q before the final step):**
- `jot.setupComplete == false`, `jot.advanced.enabled == false`, `jot.advanced.migrated == true`.
- Sidebar renders: Recents / Settings group / Help / About. No Ask Jot row; no Vocabulary sub-row.
- `Sources/Settings/ShortcutsPane.swift` lists exactly four bindable rows (Toggle Recording, Rewrite, Rewrite with Voice, plus the always-on Cancel row).
- First-run `BasicsBanner` shows the "More options live behind Advanced…" hint.
- On next launch, the wizard re-presents (because `setupComplete == false`).

**Fresh install, user completes the Setup Wizard:**
- `FirstRunState.markComplete()` runs at the wizard's final step and atomically writes `jot.setupComplete = true` AND `jot.advanced.enabled = true`.
- Post-wizard sidebar is identical to an existing v1.12 user's sidebar (Recents / Settings group with Vocabulary sub-row / Help / Ask Jot / About).
- `Sources/Settings/ShortcutsPane.swift` shows all bindable rows including Push-to-Talk (and Paste Last Result, pending Decision #1).
- First-run `BasicsBanner` hint is suppressed (Advanced is already on).

**Existing user upgrading from v1.12 (`jot.setupComplete == true` at first boot after update):**
- `AdvancedFlag.migrateIfNeeded()` writes `jot.advanced.enabled = true`, `jot.advanced.migrated = true`. No wizard interaction.
- Sidebar, shortcuts, Ask Jot routing — all unchanged from yesterday (modulo the four small things listed in `design.md` § "Existing users upgrading").

**Toggling Advanced off mid-session:**
- The `.onChange(of: advancedEnabled)` observer in `JotAppWindow` redirects `.askJot` and `.settings(.vocabulary)` selections to `.home`/`.recents`, cancels any in-flight Ask Jot stream via `chatStore.cancelStream()`, and filters `NavigationHistory.back`/`.forward` to drop entries pointing at now-hidden panes.
- No broken navigation, no stranded panes.

**Toggling Advanced back on:**
- Sidebar rows and panes reappear with state preserved (vocab list, Ask Jot history, shortcut bindings all intact).

**Speaker Labels:** card no longer appears in Transcription settings (gated by `Features.speakerLabels` at the callsite, independent of Advanced).

**Settings group collapse state:** `jot.sidebar.settingsExpanded` persists across app relaunches; the header button no longer force-expands.

---

## 9. Files read

- `/Users/vsriram/code/jot/CLAUDE.md`
- `/Users/vsriram/code/jot/Sources/App/AppSidebar.swift`
- `/Users/vsriram/code/jot/Sources/App/AppSidebarSelection.swift`
- `/Users/vsriram/code/jot/Sources/App/JotAppWindow.swift`
- `/Users/vsriram/code/jot/Sources/App/FirstRunState.swift`
- `/Users/vsriram/code/jot/Sources/App/Features.swift`
- `/Users/vsriram/code/jot/Sources/App/AppDelegate.swift`
- `/Users/vsriram/code/jot/Sources/App/NavigationHistory.swift`
- `/Users/vsriram/code/jot/Sources/Settings/TranscriptionPane.swift`
- `/Users/vsriram/code/jot/Sources/Settings/ShortcutsPane.swift`
- `/Users/vsriram/code/jot/Sources/Settings/Shortcuts/ShortcutsRowModel.swift`
- `/Users/vsriram/code/jot/Sources/Settings/RewritePane.swift`
- `/Users/vsriram/code/jot/Sources/Settings/GeneralPane.swift`
- `/Users/vsriram/code/jot/Sources/Settings/AboutPane.swift`
- `/Users/vsriram/code/jot/Sources/Vocabulary/VocabularyPane.swift`
- `/Users/vsriram/code/jot/Sources/Home/HomePane.swift`
- `/Users/vsriram/code/jot/Sources/Help/Basics/SubRowList.swift`
- `/Users/vsriram/code/jot/Sources/Help/Basics/BasicsContent.swift`
- `/Users/vsriram/code/jot/Sources/SetupWizard/Steps/DoneStep.swift`
- `/Users/vsriram/code/jot/Sources/SetupWizard/Steps/ModelStep.swift`
- `/Users/vsriram/code/jot/Sources/AskJot/HelpChatStore.swift`
- `/Users/vsriram/code/jot/Sources/MenuBar/JotMenuBarController.swift`
- `/Users/vsriram/code/jot/Resources/help-content-base.md`
- `/Users/vsriram/code/jot/Resources/fragments/*.md`
- `git log -p Sources/App/FirstRunState.swift`

## Files NOT read but might want to verify during implementation

- Full `RewritePane.swift` body (only the top half re: the allow-cloud toggle was read).
- Full `HelpChatStore.swift` (only the `isCloudAskJotEnabled` region and grounding-string region were read).
- `Sources/Help/HelpBasicsView.swift` — read line range around the sparkle icons (144-162) was inferred from grep; the full sparkle-icon implementation needs to be read to gate it correctly.
- `Sources/App/HelpNavigator.swift` — full surface not read end-to-end.
- `tools/check-help-doc-budget.swift` and the build-phase scripts — need to verify the "Home" → "Recents" grounding edit lands within budget.
