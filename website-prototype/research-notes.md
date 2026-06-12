# Website redesign — research notes (June 2026)

Raw findings backing the prototype. This is also the source material for the
upcoming competitor matrix. Not committed; lives with the prototype.

---

## 1. Google's entry

**Google AI Edge Eloquent** — quietly launched on the iOS App Store April 6–7, 2026
(no press release). Free, no caps. Offline-first: on-device Gemma-based ASR;
optional cloud-Gemini toggle for enhanced cleanup. Filler-word removal,
self-correction handling, format transforms (Key points / Formal / Short / Long),
custom keyword import from Gmail. Press says it also runs on Apple Silicon Macs.
Official page: ai.google.dev/edge/eloquent.

**Second shoe:** May 2026 — **"Rambler"**, Gemini-powered dictation built into
Gboard (Pixel/Samsung, summer 2026). TechCrunch: "bad news for dictation
startups" — standalone apps now need better accuracy, deeper features, or
**stronger privacy guarantees** to justify a separate download. Privacy is
exactly Jot's lane.

## 2. Software competitors (matrix raw data)

| Name | Price | Platform | On-device? | Account? | Key features | Positioning |
|---|---|---|---|---|---|---|
| Wispr Flow | Free (2k words/wk); Pro $15/mo or $144/yr | Mac, Win, iOS, Android | **No — cloud only**, even in "Privacy Mode" | Yes | Auto-edit "flow", tone matching, synced dictionary, SOC 2 | Category leader; had a publicized privacy incident |
| Superwhisper | Free local tier; Pro $8.49/mo, $249.99 lifetime | macOS, Win, iOS | Yes by default (local Whisper + Parakeet) | No for free local | Per-app modes, AI post-processing, meetings/files | Power-user flagship of paid on-device |
| MacWhisper | Free tier; Pro €59 one-time | macOS | Yes — fully local | No | Mostly file/YouTube/meeting transcription; dictation secondary | Indie one-time-purchase workhorse |
| VoiceInk | $25–49 one-time; source free (GPL v3, ~4.3k stars) | macOS | Yes — 100% offline | No | Per-app modes, model switching, BYOK enhancement | "Open-source alt to Superwhisper/Wispr" — closest analog |
| Aqua Voice | Free 1k words lifetime; $8/mo | Mac, Win, iOS | No — cloud (Avalon model) | Yes | Technical-vocab accuracy, 800-term dictionary, streaming | Speed/accuracy for developers |
| Willow Voice | Free 2k words/wk; $15/mo or $144/yr | Mac, Win, iOS, Android | Mostly cloud; offline mode optional | Yes | Per-app style, AI Mode, team plans | Polished cross-platform cloud |
| Monologue | Free 1k words once; $15/mo | macOS, iOS | Cloud | Yes | **Screen-aware context/tone matching**, 100+ languages | Every.to-backed, 4.9 MAS |
| Handy | **Free, MIT** | Mac, Win, Linux | Yes — fully offline | No | ~20k GitHub stars, 5.0 Product Hunt | **Most direct free/MIT rival** — but cross-platform, less Mac-native |
| OpenWhispr | Free (MIT) | Mac, Win, Linux | Yes (Whisper + Parakeet) + BYOK cloud | No for local | Custom dictionary, AI cleanup | Privacy-first open cross-platform |
| Spokenly | Free, BYOK | macOS (+iOS) | Local available | No | Comparison-page SEO machine | "Free BYOK vs $X/mo" |

Long tail: Voibe ($149 lifetime), Typeless, Dictato, MacParakeet, SpeakMac, Mumble, Amical.

## 3. Hardware (adjacent, not direct)

| Name | Price | On-device? | Notes |
|---|---|---|---|
| Plaud Note / Note Pro | $129–189 + subs ($99.99–239.99/yr) | No — Plaud cloud | "World's No.1 AI note-taking brand"; meeting capture, not at-cursor dictation |
| Plaud NotePin | $99–179 + subs | No | Wearable version |
| Limitless Pendant | $399 (or $299 + plan) | No — cloud | 100-hr battery all-day capture |
| Bee AI Pendant (Amazon) | $49 + $19/mo | No | Cheap entry, subscription model |
| Omi | $89, self-hostable | Partial (BYOK) | Developer/open angle |

All are **conversation capture + summarization** — adjacent. Jot doesn't compete
on all-day capture; it competes on "type with your voice, privately, free."

## 4. Positioning conclusions

**Wins (the message):**
- Free + MIT + Mac-native + Parakeet-on-ANE is **unoccupied territory** (Handy is the only free/MIT comp, and it's cross-platform/less native).
- 100% on-device with no caveats — leader Wispr Flow is cloud-only with a privacy incident on record.
- No account, no telemetry, no subscription — subscription fatigue ($144–180/yr) is the top complaint in 2026 comparison content.
- Apple Intelligence default means even rewrite/cleanup can be fully on-device.

**Loses (don't claim otherwise):**
- macOS-only; no Windows/iOS/Android story.
- "Free" alone is no longer unique vs Google Eloquent — privacy + native + open source is the full sentence.
- No screen-context awareness (Monologue), no meeting/file transcription (MacWhisper/Superwhisper) — out of scope by design.
- **Discovery:** Jot appears in none of the 2026 "best Mac dictation" roundups. SEO/comparison content is a real gap (competitors carpet-bomb comparison pages).

## 5. Design research → decisions taken in the prototype

From the best pages (Wispr, Superwhisper, Raycast, CleanShot, Linear):
- Verb-led headline + single download CTA above the fold; no feature lists in hero. ✅
- For hotkey apps, **rendered keycaps are the product visual** (Superwhisper). ✅ steps strip
- Show the product as real artifacts: typed transcript text, the recording pill. ✅ animated pill demo
- Monochrome + one accent (not purple); product supplies the color. ✅ black/white/red from icon
- Real, verifiable social proof only — no fabricated testimonial cards. (None yet; add real tweets/quotes when they exist.)

AI-slop avoid-list applied (sources: developersdigest.tech, impeccable.style, 925studios.co):
- ❌ purple gradients, glassmorphism, glow shadows — none
- ❌ icon-tile 3-col feature card grid / emoji icons — replaced with hover-highlight rows
- ❌ all-caps eyebrow labels — removed
- ❌ numbered 01/02/03 steps — replaced with keycap/dot/caret glyphs
- ❌ fade-in-on-scroll on every element — removed entirely
- ❌ stock phrases ("effortless", "supercharge", "all-in-one") — copy is concrete ("Run Little Snitch — you'll see silence")

Demo recommendation from research: a 5–8s muted looping screen capture of the real
dictation flow beats the CSS animation for credibility. **Follow-up for the real
ship:** record one (hotkey → pill → speech → text lands), compress to <2MB
MP4/WebM, poster fallback on mobile. The CSS typing demo is the placeholder.

## 6. LinkedIn launch checklist

- OG image: 1200×630 PNG ✅ (`assets/og-card.png`), under 1MB ✅, absolute URL ✅, `property=` attributes ✅.
- LinkedIn's crawler does not execute JS — tags must be in raw HTML ✅ (static site).
- PNG/JPEG only (no WebP/SVG). ✅
- **Before the first post:** run https://www.linkedin.com/post-inspector/ — LinkedIn caches previews ~7 days and already-published posts keep the stale card.
- If the card changes later, version the filename (og-card-v2.png).
- Posts: manual, from the personal account, via the admin composer's share intents — concrete specifics, no AI-slop phrasing.
