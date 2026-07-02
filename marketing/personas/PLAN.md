# Jot — persona campaign plan

Five user archetypes, each answering one question: **"what does speaking-instead-of-typing
buy *this* person?"** Same rules as every Jot asset:

- **Only true claims** — free · open-source · on-device (Apple Neural Engine) · press a
  hotkey, speak, text at your cursor · works in any app · no account, no subscription.
  Never speed/accuracy percentages we haven't measured, never "AI magic".
- **Plain words**, no jargon.
- **Their app, their words** — every scene shows the persona's real tool (Notes, Slack,
  Pages, Notion…) with content that person would actually produce.

Each persona ships as: 1 feed image (1080×1350) → then a 15–20s reel using the same
scene (beats below), reusing the Ori reel pipeline restyled to Jot's graphite/blue.

---

## 1. The Professor — feedback that sounds like you
**Scene:** a stack of essays; one open in Word/Pages with a feedback comment growing.
**Truth:** typed feedback shrinks to "Good point, expand." Spoken feedback keeps the
encouragement and the reasoning.

| Beat | On screen |
|---|---|
| 1 | "40 essays. Feedback due Friday." |
| 2 | "Press ⌥ Space. Say what you'd tell them in office hours." |
| 3 | Feedback paragraph lands in the margin — warm, specific, three sentences. |
| 4 | "Free. On your Mac. Nothing uploaded — their work stays theirs." |

*The privacy line matters doubly here: student work never leaves the machine.*

## 2. The Developer — the standup you didn't type
**Scene:** Slack #standup channel; a full update lands at the cursor.
**Truth:** Jot's own downloads come from this crowd; keep it.

| Beat | On screen |
|---|---|
| 1 | "Standup in 2 minutes." |
| 2 | "⌥ Space → say what you did, what's next, what's blocked." |
| 3 | Three tidy bullets appear in Slack. |
| 4 | "Free, open-source, on-device. Back to the code." |

## 3. The Writer — first drafts at speaking speed
**Scene:** Pages/Scrivener, blank page → a paragraph of rough draft.
**Truth:** speaking defeats the blank page; editing comes later.

| Beat | On screen |
|---|---|
| 1 | "The blank page wins when you type at it." |
| 2 | "Talk the scene out instead." |
| 3 | A rough, alive paragraph fills the page. |
| 4 | "Draft out loud. Edit with your hands. Free, on-device." |

## 4. The Student — the lecture, in your own words
**Scene:** Apple Notes, "BIO 201 — recap" filling with a spoken summary.
**Truth:** explaining out loud right after class is retrieval practice (don't claim
grades improve — claim only what the app does: capture the explanation).

| Beat | On screen |
|---|---|
| 1 | "Walking out of lecture, it's all still in your head." |
| 2 | "⌥ Space — explain it to yourself before it fades." |
| 3 | A recap in the student's own words lands in Notes. |
| 4 | "Free. No account. Works offline in the library basement." |

## 5. The Meeting-Taker — notes without leaving the call
**Scene:** Zoom call on one side, Notion minutes on the other; a decision lands as a bullet.
**Truth:** existing storyboard ("meeting notes in real-time"), promoted to persona.

| Beat | On screen |
|---|---|
| 1 | "In a meeting. A decision just happened." |
| 2 | "One hotkey. Say it without breaking eye contact." |
| 3 | The decision appears as a bullet in Notion. |
| 4 | "Still listening. Nothing left your Mac." |

---

## Production notes
- **Images:** `render-scenes.mjs` builds all five 1080×1350 PNGs into `out/` from the
  HTML scenes in `scenes/` (self-contained, brand palette from `kit/products/jot.config.mjs`).
- **Reels:** reuse the Ori `produce-reel-*.mjs` pattern (ori-cognitive-health →
  `website/scripts/`) restyled with Jot's palette; one scene file per persona already
  carries the beats.
- **Rotation:** one persona per posting day; the developer persona stays the anchor,
  the other four widen the audience. Console (`jamyboss.ideaflow.page/jot/`) lists
  assets from this repo via raw.githubusercontent URLs — add entries to
  `marketing/mission-control` data when the reels exist.
