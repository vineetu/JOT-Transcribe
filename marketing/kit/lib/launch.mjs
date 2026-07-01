// Off-page launch drafts — the backlinks/authority that on-page SEO can't buy.
// These are drafts for a human to publish (I can't post). One file per channel.

export function launchPosts(cfg) {
  const l = cfg.launch || {};
  const url = cfg.appStoreUrl;
  const diffs = (l.differentiators || cfg.friend.cards.map((c) => c.h3)).map((d) => `- ${d}`).join("\n");
  const subs = l.targetSubreddits || [];

  const producthunt = `# Product Hunt — ${cfg.name}

**Tagline (≤60 chars):** ${cfg.oneLiner}

**First comment (maker's note):**
Hi everyone — I built ${cfg.name} because ${l.why || "I wanted " + cfg.oneLiner.toLowerCase() + " without the usual catch."}

What makes it different:
${diffs}

It's **free**, and your data stays on your device. No account, no subscription.
Would love your honest feedback — what would make it a daily habit for you?

**Gallery order:** hero → core feature → privacy → free. Reuse the App Store screenshots.
**Launch day:** post 12:01am PT; line up a few honest upvotes/comments; reply to every comment.
**Link:** ${url}
`;

  const showhn = `# Show HN — ${cfg.name}

**Title:** Show HN: ${cfg.name} – ${cfg.oneLiner}

**Body:**
${l.hnBody || `I made ${cfg.name}: ${cfg.oneLiner}. ${cfg.meta.description}`}

Tech notes HN tends to care about:
${(l.hnTech || ["On-device / privacy model", "How it works under the hood", "What's free and why"]).map((t) => `- ${t}`).join("\n")}

It's free. Happy to answer anything about the approach.
Link: ${cfg.domain ? "https://" + cfg.domain + "/" : url}

**Tips:** post 8–10am ET on a weekday; no marketing voice — HN rewards plain, technical honesty; stay in the thread.
`;

  const reddit = subs.map((s) => `# Reddit — r/${s.sub}

**Suggested title:** ${s.title || cfg.oneLiner}

**Body:**
${s.body || `${cfg.meta.description}\n\nIt's free and on-device. Not selling anything — genuinely want feedback from people in this community.`}

**Rules first:** read r/${s.sub}'s self-promo rules before posting. Lead with value, disclose you're the maker, never spam. Link in a comment if the sub prefers it.
**Link:** ${url}
`).join("\n\n---\n\n");

  return { producthunt, showhn, reddit };
}
