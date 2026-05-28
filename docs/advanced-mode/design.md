# Advanced mode

A product spec for the Advanced toggle, the Home → Recents rename, and three same-release fixes that ship as one bundle.

---

## Problem statement

Jot's first-run surface area is wider than a beginner needs. A new user installs the app, finishes the Setup Wizard, and is dropped into a sidebar that lists Custom Vocabulary, Ask Jot (a chatbot grounded in our help content), Speaker Labels (in-progress and disabled), and a Shortcuts pane that exposes Push-to-Talk and Paste Last Result alongside the two recording hotkeys most people actually use.

The features themselves are good. The problem is **density at the wrong moment.** A user who just learned the press-hotkey-and-speak loop doesn't want a chatbot suggestion in the sidebar. They want to dictate, see the transcript paste at the cursor, and move on. The advanced surfaces are clutter for that user; they're load-bearing for the power user who's been using Jot for six months.

The product question: how do we keep the power-user features available without making them the first thing a new user sees?

**The answer this spec implements:** one master toggle, called "Advanced," in Settings → General. When off, four power-user surfaces disappear. When on, the app looks exactly like it does today. New users start with it off, but completing the Setup Wizard turns it on — see migration policy below. Existing users keep it on (nothing changes for them).

---

## What ships in this release

Five user-visible changes, bundled as one release:

1. **Advanced toggle** in Settings → General. Master switch — there are no per-feature sub-toggles.
2. **Home renamed to Recents** in the sidebar and the pane title.
3. **Ask Jot allow-cloud toggle removed.** Ask Jot now uses the same AI provider you've configured for everything else, unconditionally.
4. **Speaker Labels card bug fixed.** The card stops showing up in Transcription settings while the feature is still in-progress.
5. **Settings group in the sidebar is now collapsible** — and the expand/collapse state persists across launches.

All five ship together. There is no staggered rollout from the user's perspective.

---

## What's behind the Advanced toggle

When Advanced is **off**, these three surfaces are hidden:

| Surface | Where it lives today | Behavior with Advanced off |
|---|---|---|
| **Custom Vocabulary** | Sidebar sub-row under Settings | Sub-row hidden. Vocab data on disk is preserved. |
| **Ask Jot chatbot** | Sidebar row + About-pane section + Help Basics sparkle icons | Sidebar row hidden. About section hidden. Sparkle "ask me" affordances in Help hidden. |
| **Push-to-Talk shortcut row** | Settings → Shortcuts | Row hidden. Any existing PTT binding still fires — we don't unbind it. |

*Paste Last Result may also be gated — see Decision #1.*

When Advanced is **on**, the app looks and behaves exactly as it does today. Nothing new, nothing removed.

Surfaces that **stay visible regardless** of the toggle:

| Surface | Why it stays |
|---|---|
| Recents (the recordings list) | The core landing surface. |
| Help (the in-app prose walkthrough) | Product literacy, not a power-user feature. Every Settings popover deep-links into Help. |
| Settings (General, Transcription, Prompts, Sound, AI, Shortcuts) | The configurable surface beginners and power users both need. |
| About | Always visible. |
| Donations | Reached via a Recents card and an About section, not the sidebar. Unchanged. |
| Speaker Labels card in Transcription settings | Hidden, but via the existing kill switch — not the Advanced toggle. See "Speaker Labels card bug" below. |

The "Show All Recordings…" menu bar entry, the Setup Wizard, the recording overlay, and all hotkey routing behave identically with Advanced on or off.

---

## Who's affected, and how

### Existing users upgrading from v1.12

**No visible change.** When the update lands, Advanced is on for them. Their sidebar, their shortcuts, their Ask Jot pane — everything looks the same. They'll see four small things:

1. The sidebar entry "Home" is now "Recents."
2. The Settings group in the sidebar is now collapsible (it's expanded by default, so until they collapse it, nothing looks different).
3. If they had Ask Jot configured to use a cloud provider, a one-time banner appears the next time they open Ask Jot explaining that Ask Jot now follows their global AI provider directly.
4. The Speaker Labels card that used to leak into Transcription settings is gone (it should never have been visible).

If they look in Settings → General, they'll see a new "Advanced" toggle at the bottom of the page, on. They can flip it off and the surface trims down.

### New users installing for the first time

Advanced starts off for a fresh install. When the user completes the Setup Wizard — which introduces Custom Vocabulary, AI features, and Prompts — Advanced auto-flips on. A user who quits the wizard early stays in slim mode until they manually flip Advanced on in Settings → General.

In slim mode (wizard not yet completed, or quit early), the sidebar reads: Recents, Settings (General, Transcription, Prompts, Sound, AI, Shortcuts), Help, About. The Shortcuts pane shows four bindable rows: Toggle Recording, Rewrite, Rewrite with Voice, plus Escape (always-on cancel).

A one-line hint sits in the first-run banner on Recents for users who land in slim mode: "More options — custom vocabulary, the Ask Jot chatbot, and other power-user shortcuts — live behind 'Advanced' in Settings → General." Dismissible, just like the rest of the banner.

The Setup Wizard's "Advanced, for later" card and the Vocabulary-boost model offer are reworded to point at the Advanced toggle as the discoverability gateway, instead of naming Settings paths that don't exist yet for them.

### Power user who wants Custom Vocabulary back after a fresh install

They install Jot fresh, finish the wizard, land on the slimmer surface. They've used Jot before; they know Custom Vocabulary exists. They open Settings → General, scroll to the bottom, flip Advanced on. Vocabulary appears as a sidebar sub-row under Settings. Their workflow resumes.

### User who flips Advanced off after using it for a while

They've had Ask Jot configured and a Push-to-Talk binding for months. They decide to clean up their sidebar. They flip Advanced off in Settings → General.

- The Ask Jot row disappears from the sidebar.
- The Push-to-Talk row disappears from Settings → Shortcuts.
- Their Push-to-Talk hotkey **still fires.** We don't deactivate the binding — they deliberately bound it.
- If they were mid-conversation in Ask Jot, the active stream is canceled and the sidebar redirects them to Recents.
- Their Vocab list is preserved on disk. So is their Ask Jot conversation history. Nothing is deleted.

If they flip Advanced back on later, everything reappears with the same state.

---

## Migration policy

Plain language:

- **Existing users see no change.** The moment they install the update, Advanced is on. The sidebar, the shortcuts, the Ask Jot routing — all behave like they did yesterday. (Except the four small things listed under "Existing users upgrading" above.)
- **New installs start in slim mode.** Advanced is off. The first-run banner mentions the toggle so it's discoverable.
- **Completing the Setup Wizard turns Advanced on.** The wizard introduces Custom Vocabulary, AI features, and Prompts; once a user has been walked through them, hiding them would be a contradiction. A user who quits the wizard mid-flow without completing keeps Advanced off.
- **Toggling Advanced never deletes data.** Hidden surfaces preserve their data on disk. Custom vocab terms, Ask Jot history, shortcut bindings — all preserved across off → on → off.
- **Privacy preference is preserved for the Ask Jot change.** If you previously opted *out* of letting Ask Jot use your cloud provider, Ask Jot will continue using Apple Intelligence after this release. We don't silently flip a stated privacy preference. The first-open banner only appears for users whose behavior is actually changing.
- **Reset settings clears the toggle.** Soft reset and hard reset both clear the Advanced flag. After a reset, the user is treated as a fresh install (Advanced off).

---

## Other changes shipping in this release

### 1. Home → Recents

The sidebar entry "Home" and the pane title both become "Recents." The icon stays as the house symbol (we can change it later if Recents wants its own icon).

This is a strings-only rename. Internal symbols and storage keys keep their "home" names — the rename is purely user-facing.

### 2. Ask Jot allow-cloud toggle removed

Today, in Settings → AI, when you have a cloud provider selected (OpenAI, Anthropic, Gemini), there's a separate toggle "Allow Ask Jot to use this provider." Off by default. If the toggle is off, Ask Jot is pinned to Apple Intelligence regardless of your global provider choice; if on, Ask Jot uses the cloud provider.

We're removing that toggle. Ask Jot now follows your configured AI provider unconditionally. To keep Ask Jot on Apple Intelligence, switch your global provider to Apple Intelligence in Settings → AI.

Exception: users who **explicitly** opted out before (toggle was set to off) keep the old behavior — Ask Jot stays on Apple Intelligence for them. We don't silently change a stated privacy preference. They get a one-time banner explaining the change the next time they open Ask Jot.

### 3. Speaker Labels card bug fixed

There's an in-progress Speaker Labels feature, currently disabled by a kill switch. The kill switch correctly hides it from the sidebar. But a card for it has been leaking into Transcription settings — clicking it would jump to a pane that has no sidebar entry. That's the bug. We're fixing it by routing the card through the same kill switch the sidebar already uses.

This fix is independent of Advanced. When Speaker Labels ships for real, it'll be gated by the Advanced toggle.

### 4. Settings group is collapsible

The sidebar's Settings group already had a disclosure triangle, but it didn't actually work — the state didn't persist, and clicking the header re-expanded it. Now the chevron actually collapses the group, and the state survives window close and app relaunch.

Default: expanded. Both new and existing users see Settings expanded the first time. Once a user collapses it, it stays collapsed until they expand again.

Header click behavior changes slightly: clicking "Settings" in the sidebar still navigates to General, but no longer force-expands the group. To expand, click the chevron. This matches macOS System Settings.

---

## What's NOT in scope

Things people might assume are part of this release but aren't:

- **Onboarding redesign.** The Setup Wizard gets two copy tweaks (Advanced hint card, Vocabulary-boost model offer). Nothing else.
- **Settings reorganization beyond the rename.** The Settings sub-panes stay in their current order. Transcription is still under Settings; AI is still under Settings. We're not flattening the hierarchy.
- **Telemetry.** No analytics, no event tracking on Advanced toggle flips. Jot has zero telemetry; that doesn't change.
- **Per-feature toggles.** There's one master switch. You can't hide Ask Jot but keep Vocabulary, or vice versa. Adding granular toggles was considered and rejected.
- **Gating the Help tab.** Help stays visible regardless. The Custom Vocabulary section in Help Basics will still be readable to an Advanced-off user — that's intentional. Help is where you go to *learn* a feature exists.
- **Cloud transcription, VAD, file upload.** Still out of scope for the product.

---

## Support implications

New questions users will ask, and what the canned answers are:

| Question | Answer |
|---|---|
| "Where did Custom Vocabulary go?" | "Settings → General → toggle on Advanced. Vocabulary reappears under Settings in the sidebar." |
| "Where did Ask Jot go?" | "Same answer — Advanced toggle in Settings → General." |
| "Why is Ask Jot now using my OpenAI API key when I opened it?" | "Ask Jot now follows your configured AI provider. To keep Ask Jot on Apple Intelligence, switch your global provider to Apple Intelligence in Settings → AI." |
| "Why did Home become Recents?" | "Cosmetic rename. Same pane, same recordings, same behavior." |
| "I can't find Push-to-Talk in Shortcuts." | "It's a power-user shortcut hidden behind Advanced. Settings → General → toggle Advanced on." |
| "My Push-to-Talk hotkey still fires but I can't see it in Settings." | "Hotkey bindings stay active when Advanced is off — we don't unbind them. Re-enable Advanced to see/edit the row." |
| "I had Ask Jot set to Apple Intelligence before the update and it's still on Apple Intelligence — why?" | "Your previous opt-out is preserved. Behavior is unchanged for you." |
| "I'm a new user and I finished setup, why do I see all these features?" | "Finishing the Setup Wizard turns Advanced on automatically because the wizard introduces those features. You can turn Advanced off in Settings → General to slim the sidebar down." |

Release notes should mention: the Advanced toggle, the Home → Recents rename, the Ask Jot provider behavior change (with the explicit note that previous opt-outs are preserved), and the Settings group being collapsible. The Speaker Labels card fix is invisible to most users (it was a bug that affected a visible-but-dead card) and can be omitted from release notes or grouped under "bug fixes."

---

## Decisions needed from you

Ten open decisions. Each has a recommendation; none are blocking.

### 1. Paste Last Result row visibility

Hide it when Advanced is off, or keep it visible alongside Toggle Recording / Rewrite / Rewrite with Voice / Escape?

- **Recommended: hide.** Same shape of feature as Push-to-Talk (niche global hotkey). Trimming Shortcuts to four bindable rows is the cleaner story.
- **Alternative: keep visible.** You only named PTT in the brief; Paste Last is arguably more discoverable than PTT.

### 2. PTT/hotkey behavior when row is hidden

When Advanced is off and a Push-to-Talk binding exists, should the hotkey still fire?

- **Recommended: hotkey keeps firing.** The user deliberately bound it; hiding the row from Settings doesn't mean they want it deactivated.
- **Alternative: unregister on Advanced=off.** Strict UI/runtime parity. Stronger behavior change.

### 3. "Advanced" wording

What do we call the toggle?

- **Recommended: "Show advanced features"** with subtitle "Custom vocabulary, Ask Jot chatbot, push-to-talk, and other power-user options."
- **Alternatives:** "Advanced" (terse), "Power user mode" (cute but jargon-y), "Show all features" (loses the framing).

### 4. Speaker Labels gating when the feature ships

When Speaker Labels actually ships (not now), how is it gated for beginners?

- **Recommended: gate on Advanced only.** Retire the kill switch once the feature is ready.
- **Alternative: stack the kill switch with Advanced.** Defeats the kill-switch idiom.

### 5. Internal symbol rename for Home → Recents

Right now we're doing a user-facing-strings-only rename. Internal symbols still say "home." Should we also rename the internal symbols?

- **Recommended: defer.** Future maintenance task, file under `rename-internal-symbols-deferred.md`. The strings-only diff is small and safe.
- **Alternative: full rename now.** Bigger diff, touches more files, including stringly-typed Objective-C selectors that don't fail at compile time.

### 6. Recents icon

Keep the house icon, or switch to something more "recents"-flavored?

- **Recommended: keep the house icon.** It's familiar; we can change later.
- **Alternatives:** clock, tray.

### 7. Reset behavior for the Settings-group collapse state

When the user runs Soft Reset (clears preferences, keeps library) or Hard Reset (wipes everything), should the Settings-group expand/collapse state reset too?

- **Recommended: reset on Hard, preserve on Soft.** Soft reset's copy is "preferences, API keys, shortcuts" — a UI presentation preference is arguably distinct.
- **Alternatives:** always reset, or never reset.

### 8. Settings header click — navigate-only vs navigate + expand

Today, clicking the "Settings" header in the sidebar both navigates to General AND force-expands the group. With persistent collapse state, what should it do?

- **Recommended: navigate-only.** Clicking the header navigates to General without changing the expand state. To expand, use the chevron. Matches macOS System Settings.
- **Alternative: keep today's "navigate + force-expand."** But this conflicts with the persistent-collapse promise — any incidental header click would re-expand the group.

### 9. Discoverability mechanism for the Advanced toggle

How does a new user find out the Advanced toggle exists?

- **Recommended: add one line to the first-run banner on Recents.** "More options — custom vocabulary, the Ask Jot chatbot, and other power-user shortcuts — live behind 'Advanced' in Settings → General." Already dismissible.
- **Alternatives:**
  - Persistent hint card on the Recents pane (more chrome).
  - Intro line in the Help Basics tab (only the curious-enough-to-open-Help user sees it).

### 10. Orphan "Home" string in localization

After the rename, the localization catalog has an orphan "Home" entry. Cosmetic-only — the UI shows "Recents" at runtime regardless.

- **Recommended: leave it or remove it; behavior is identical.** Pick whichever feels lower-friction at implementation time.

---

## Success criteria

What "done" looks like:

- A new install where the user quits the Setup Wizard early shows the slim sidebar (Recents / Settings / Help / About) and the four-row Shortcuts pane.
- A new install where the user completes the Setup Wizard ends with Advanced on; the sidebar matches an existing v1.12 user's sidebar.
- An existing install on update shows no change to their sidebar, shortcuts, or Ask Jot routing (modulo the four small things in "Existing users upgrading").
- A user who flips Advanced off mid-session has their sidebar trim down, with no broken navigation, no stranded panes, and no orphaned background work (in-flight Ask Jot streams are canceled cleanly).
- A user who flips Advanced back on has everything return with the same state.
- The Speaker Labels card no longer appears in Transcription settings.
- Existing users who had Ask Jot pinned to Apple Intelligence (explicit opt-out) keep that behavior. Existing users with Ask Jot enabled for a cloud provider see an explanatory banner the first time they open Ask Jot.
- The Settings group in the sidebar can be collapsed and the state persists across app relaunches.

---

## Risks (from a product lens)

- **Discoverability of the toggle.** A new user who's heard about Custom Vocabulary from a friend opens the app and can't find it. Mitigation: the first-run banner hint. Risk that users dismiss the banner without reading is real — see Decision #9 alternatives.
- **Support burden during the transition.** "Where did my X go?" questions for the first few weeks after release. Mitigation: release notes call out the Advanced toggle; canned answers above are short and consistent.
- **Ask Jot routing surprise.** A user with a cloud provider who never explicitly toggled "Allow Ask Jot to use this provider" opens Ask Jot post-update and the chatbot routes their question to OpenAI/Anthropic/Gemini using their API key. Mitigation: the one-time banner explains the change. But some users may dismiss it without reading.
- **User confusion when Advanced is flipped off while sitting on Ask Jot.** Mitigated technically (selection redirects to Recents, in-flight streams cancel) — but a user might briefly think the pane crashed.
- **The "Advanced" framing might feel like an expert/beginner split** for the whole product. Mitigation: the toggle is at the bottom of Settings → General, not at the top. Subtitle softens the framing.
- **The Advanced=OFF state may be rare in practice.** Most new users complete the Setup Wizard, which now auto-flips Advanced to ON. The toggle's main value is as an opt-out for users who want to declutter their sidebar after the fact, not as a first-run-only filter. Mitigation: this is the owner's deliberate design choice; the toggle still serves its decluttering purpose for any user (new or existing) who wants it.

---

Engineering details, file-by-file implementation plan, storage key contracts, migration sentinel logic, and code-level risks live in `engineering-notes.md`.
