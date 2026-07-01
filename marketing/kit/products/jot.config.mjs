// Jot (Jot Transcribe) — marketing config. Second real product, to prove the
// kit generalizes beyond Ori. Facts sourced from https://jot-transcribe.com/.
// Copy + palette here are a faithful scaffold; TODO markers flag the few fields
// to confirm (privacy/support URLs, GSC/Bing tags, screenshot assets).

const APP = "https://apps.apple.com/us/app/jot-transcribe/id6766447330";
const DOMAIN = "jot-transcribe.com";
const HOME = `https://${DOMAIN}/`;

export default {
  name: "Jot",
  domain: DOMAIN,
  appStoreUrl: APP,
  appStoreId: "6766447330",
  operatingSystem: "macOS, iOS",
  category: "dictation",
  oneLiner: "Speak, and it's written.",
  schemaDescription:
    "Free, on-device dictation for Mac and iPhone. Press a hotkey, talk, and the text appears wherever your cursor is — instantly, and completely private. Your voice becomes text right on your machine and never leaves it. Open-source, no account, no subscription.",

  // Graphite + electric-blue palette (re-themes the same template Ori uses).
  brand: {
    serif: "ui-serif,'New York','Iowan Old Style',Georgia,serif",
    meta: "-apple-system,BlinkMacSystemFont,system-ui,sans-serif",
    night: "#0E1116", night2: "#11151B", panel: "#161B22", ink: "#EDF1F6", soft: "#B7C0CC", faint: "#6E7A88",
    sage: "#5B9DFF", amber: "#E0A23C", clay: "#E0653C", line: "rgba(91,157,255,.16)",
    screen: "#EEF1F5", paper: "#F5F7FA", paperHi: "#FFFFFF", pink: "#10141A", pmuted: "#5B6573", phair: "rgba(16,20,26,.10)",
    forest: "#13233D", sageDk: "#2D6CCB",
    ctaInk: "#06101F", bezel: "#05070A",
    glowTriple: "91,157,255", glow2Triple: "120,180,255", amberGlowTriple: "224,162,60",
    heroTop: "#0B0E13", heroMid: "#0E1219", heroBot: "#080A0E",
    showTop: "#0E1116", showMid: "#141A22", friendMid: "#121821",
    lockup: { plain: "jot" } // plain serif wordmark — no over-letter mark
  },

  verification: { gscTag: "", bingTag: "" }, // TODO: verify jot-transcribe.com in GSC + Bing, paste tags

  meta: {
    title: "Jot — speak, and it's written",
    description: "Free, on-device dictation for Mac and iPhone. Press ⌥Space, talk, and the text appears wherever your cursor is. Private by design — your voice never leaves your machine.",
    ogTitle: "Jot — speak, and it's written",
    ogDesc: "Press a hotkey, talk, and the words land at your cursor in any app. Free, on-device, and completely private.",
    twitterDesc: "Free, on-device dictation for Mac & iPhone. Speak, and it's written."
  },

  og: { tag: "Speak, and it's written.", sub: "free · on-device · Mac & iPhone", bgTop: "#10203A", bgBot: "#06080C" },

  // No screenshot assets wired yet → the showcase section is skipped automatically.
  // TODO: add a shotsDir of Mac/iPhone screenshots to light up the showcase.

  nav: {
    links: [
      { label: "How it works", href: "#how" },
      { label: "Why Jot", href: "#friend" },
      { label: "Privacy", href: "#honest" }
    ],
    cta: { label: "Get Jot", href: APP }
  },

  hero: {
    kicker: "Free · on-device · Mac & iPhone",
    h1: "Speak, and it's written.",
    sub: "Press a hotkey, talk, and the words appear wherever your cursor is. Free, on-device dictation for Mac and iPhone — your voice becomes text right on your machine, and never leaves it.",
    ctaPrimary: { label: "Get Jot — free", href: APP },
    ctaGhost: { label: "See how it works", href: "#how" },
    fine: "Free, open-source — and nothing ever leaves your device.",
    letter: {
      date: "⌥Space — dictating",
      salutation: "Meeting notes",
      lines: [
        { t: "Let's ship the beta on Friday. " },
        { t: "I'll own the release notes, " },
        { t: "and we'll sync Thursday at ten to clear the last blockers." }
      ]
    }
  },

  story: {
    h2: 'Your voice, turned to text — <span class="accent">right where you\'re typing.</span>',
    p: "Stop switching apps to dictate. Press ⌥Space in any app — Mail, Slack, your editor, a chat box — talk, and the text lands at your cursor. It's instant, it's private, and it works the same everywhere."
  },

  friend: {
    kicker: "why Jot",
    h2: "Everything dictation should be. Nothing it usually is.",
    lede: "No cloud, no account, no catch.",
    cards: [
      { h3: "It works in every app.", p: "A global hotkey drops text right at your cursor — Mail, Slack, Notes, your editor, any prompt box. No copy-paste, no app-switching." },
      { h3: "It never leaves your Mac.", p: "Your voice is turned into text on-device, instantly and completely private. Nothing is ever sent to a server, and there's no telemetry." },
      { h3: "It's free, with no account.", p: "No subscription, no usage limits, no sign-up. Jot is free and open-source." },
      { h3: "It remembers what you said.", p: "A searchable history of your dictations, with audio replay — so nothing you spoke is lost." }
    ]
  },

  how: {
    kicker: "how it works",
    h2: "Three keys to talking instead of typing.",
    beats: [
      { when: "Press", h3: "⌥Space, in any app", p: "Hit the hotkey from wherever you're working. Toggle or hold-to-talk — your choice." },
      { when: "Talk", h3: "Say it your way", p: "Speak the way you'd speak. Jot turns your voice into text on your Mac, instantly." },
      { when: "Done", h3: "It appears at your cursor", p: "The text lands exactly where you were typing — no copy-paste, no switching windows." }
    ],
    pillars: [
      { h3: "On-device, always", p: "Your voice is transcribed right on your Mac. Nothing is ever sent to the cloud, and there is no telemetry." },
      { h3: "Free and open", p: "No subscription, no account, no usage limits. Jot is free and open-source." }
    ]
  },

  faq: {
    kicker: "ask away",
    h2: "Questions, answered — plainly.",
    faqs: [
      { q: "Is Jot really free?", a: "Yes — completely. No subscription, no usage limits, and no account. Jot is free and open-source." },
      { q: "Does my voice go to the cloud?", a: "No. Your voice is turned into text right on your Mac — instantly, and completely private. Nothing is ever sent to a server." },
      { q: "Which apps does it work in?", a: "Any app. Press ⌥Space and the text appears wherever your cursor is — Mail, Slack, Notes, your editor, or a chat box." },
      { q: "What do I need to run it?", a: "A Mac on Apple Silicon running macOS 14 or later. There's an iPhone keyboard too, so you can dictate on the go." },
      { q: "Can I use push-to-talk?", a: "Yes. Choose toggle mode or hold-to-talk, whichever fits how you work." },
      { q: "Can I see what I dictated before?", a: "Yes. Jot keeps a searchable history of your dictations with audio replay." },
      { q: "Can I dictate into developer and chat tools?", a: "Yes. Because Jot types at your cursor in any app, you can dictate straight into your editor, terminal, or a chat box." },
      { q: "Is there an iPhone version?", a: "Yes. Jot includes an iPhone keyboard, so you can dictate on your phone as well as your Mac." }
    ]
  },

  closing: {
    h2: "Stop typing what you could say.",
    p: "Free, on-device, and it never leaves your machine. Press a key and talk.",
    cta: { label: "Get Jot — free", href: APP }
  },

  footer: {
    links: [
      { label: "Privacy", href: HOME }, // TODO: real privacy URL
      { label: "Support", href: HOME }  // TODO: real support URL
    ]
  },

  aso: {
    schemaCategory: "DeveloperApplication",
    title: "Jot: On-Device Dictation",
    subtitle: "Speak, and it's written",
    keywords: ["dictation", "voice to text", "speech to text", "transcribe", "dictate", "voice typing", "hotkey", "on-device", "private", "offline", "keyboard", "productivity"],
    promo: "Press ⌥Space, talk, and the text appears wherever your cursor is. Free, on-device dictation for Mac and iPhone — your voice never leaves your machine.",
    description:
      "Jot is free, on-device dictation for Mac and iPhone.\n\nPress a hotkey, talk, and the words appear wherever your cursor is — in any app. Your voice is turned into text right on your machine, instantly and completely private.\n\n• Works in every app — text lands at your cursor\n• On-device — nothing is ever sent to the cloud\n• Free and open-source, with no account\n• Toggle or push-to-talk\n• Searchable dictation history with audio replay\n• iPhone keyboard included\n\nSpeak, and it's written.",
    screenshots: ["Press ⌥Space in any app", "Text lands at your cursor", "On-device & private", "Searchable history", "Free & open-source"],
    categories: ["Productivity", "Utilities"]
  },

  launch: {
    why: "I wanted dictation that just works in every app and never sends my voice to the cloud — so I built it, free and open-source.",
    differentiators: [
      "Types at your cursor in any app via a global hotkey",
      "On-device — your voice never leaves the machine",
      "Free and open-source, no account",
      "Searchable dictation history with audio replay"
    ],
    hnBody: "Jot is free, on-device dictation for Mac and iPhone. Press ⌥Space, talk, and the text appears at your cursor in any app. Transcription runs on-device; nothing is sent to the cloud. It's open-source.",
    hnTech: ["On-device speech-to-text — no network", "How text is injected at the cursor across apps", "Open-source; no telemetry"],
    targetSubreddits: [
      { sub: "macapps", title: "I built a free, on-device dictation app for Mac (types at your cursor in any app)", body: "Free and open-source. Press ⌥Space, talk, and the text appears wherever your cursor is. Transcription is fully on-device. Would love feedback from this community." },
      { sub: "productivity", title: "Free dictation that works in every app and never touches the cloud", body: "Made a free, on-device dictation tool for Mac + iPhone. Hotkey, talk, text at your cursor — Mail, Slack, editor, anywhere. Genuinely after feedback on what would make it part of your daily flow." }
    ]
  }
};
