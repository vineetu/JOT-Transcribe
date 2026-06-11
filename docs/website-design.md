# Jot Website — Design Specification

Design system and page spec for https://jot.ideaflow.page/, shipped June 2026
(full redesign; replaced the original blue-accent single-page site). The site
is static — `website/index.html` (public) and `website/admin/index.html`
(Mission Control dashboard) — with all CSS inline. If the pages and this doc
diverge, the pages win — update this doc.

Research backing the design decisions (competitor landscape, AI-slop
avoid-list, LinkedIn OG specs) lives in `docs/research/website-redesign-2026.md`.

---

## Brand

The wordmark is **pure text**: "jot" set in DM Sans 600, where the j is a
dotless ȷ (U+0237) carrying a **three-bar waveform tittle** — the motif from
the iPhone app icon — colored with the iPhone icon's blue gradient
(`#3AA6F8 → #0085E1`). Black letterforms on the public page, white on the
dark admin page. No boxed icon in the nav.

Two accent tokens, used semantically:

| Token | Value | Source | Role |
|---|---|---|---|
| `--accent` | `#CE231D` | Mac app icon's dot | "Recording / live" cues: pulsing i-tittle in the hero headline, dots in download buttons, rec indicator in the demo pill |
| `--wave` | `#1496F0` (flat); bars use the gradient | iPhone app icon background | The brand wave in the wordmark |

Known gap: the Mac app icon (black, red dot) and iPhone app icon (blue, white
wave) still differ from each other; the website defines the target identity
(black j + blue wave). The OG card and favicon currently use the Mac icon.

## Layout system — golden ratio

- Type scale on powers of φ: 1rem body → 1.272 (hero subtitle) → 1.618
  (feature titles) → 2.618 (section headings) → 4.236rem (hero h1), the
  display sizes fluid via `clamp()`.
- Spacing on the Fibonacci ladder: 13/21/34/55/89/144px for paddings, gaps,
  margins, radii.
- Container `max-width: 987px`; demo card 610px (= 987/φ); feature rows split
  `1fr : 1.618fr` (title : description).
- Nav 65px tall with the wordmark at 40px (≈ 1/φ of the bar).

## Typography

Google Fonts: **Source Serif 4** (300/400/600) for display headings and
feature-row titles; **DM Sans** (400/500/600) for everything else. Admin page
adds **DM Mono** for numbers/URLs. Hero headline: "Speak, and it's wrıtten."
— the i is a dotless ı whose tittle is a pulsing red dot (same 2.4s pulse as
the recording cues).

## Public page structure

1. **Nav** (fixed, frosted): wordmark · Features · GitHub · Download button.
2. **Hero**: headline → one-line pitch ("Free, on-device dictation for Mac
   and iPhone…") → **animated demo card** (dark, recording pill with waveform
   + "esc to cancel" keycap, transcript typing loop) → "Where will you use
   it?" → **dual CTAs**: Download for Mac (DMG) / Get it for iPhone (App
   Store id6766447330). JS swaps primary/secondary on iPhone visitors and
   reveals a "copy the link for your Mac" hand-off button.
3. **Steps strip**: three steps led by product glyphs (⌥ space keycaps, red
   dot, blinking caret) — no numbered circles.
4. **Features**: hover-highlighted rows (serif title left, description
   right): On-device transcription · Works in every app · Rewrite by voice ·
   Speak your prompts · Cleanup that keeps your voice · Searchable history ·
   On your iPhone, too · Free. Actually free.
5. **Privacy strip** (black): "No cloud. No account. No telemetry." with the
   $144/yr-cloud-competitor contrast line.
6. **Download**: same dual CTAs.
7. **Footer**: credit, MIT, GitHub, Donations.

Deliberately absent (2026 AI-slop tells): gradients on chrome, glassmorphism,
emoji icon grids, all-caps eyebrow labels, numbered 01/02/03 steps,
scroll-fade-in animations, stock copy. Specifics over slogans throughout.

## Admin page (`/admin/`, "Mission Control")

Unlisted, `noindex`, no auth (reads only public data). Dark console theme,
React 18 + htm via esm.sh (no build step). Panels: live GitHub metrics
(per-release DMG download counts, stars), post composer (localStorage drafts,
UTM links, share-intents for LinkedIn/X/Reddit/HN), LinkedIn card preview,
GoatCounter traffic embed (connect-your-code), publish calendar, agent brief.
App Store installs are not available (no public API).

## Meta / social

OG card `website/assets/og-card.png` (1200×630 PNG, generated from the Mac
icon). Full OG + Twitter tags in static HTML (`property=` attributes —
LinkedIn's crawler doesn't run JS). Before any LinkedIn change, re-run the
Post Inspector (≈7-day cache); version the filename if the card changes.

## Technical constraints

- No build step; pages are self-contained (admin pulls React from esm.sh).
- External requests on the public page: Google Fonts only (+ GoatCounter if
  enabled — script ships commented out with a placeholder code).
- JS is progressive enhancement; core content and download links work
  without it.
- Mobile breakpoint 680px: rows stack, steps stack, wordmark 2rem.
