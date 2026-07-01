// App Store Optimization copy — the highest-leverage channel for an app, since
// most installs come from App Store search, not Google. Produces paste-ready
// listing copy from config: title (≤30), subtitle (≤30), 100-char keyword field,
// and a promo-text + description draft.

const cap = (s, n) => (s.length <= n ? s : s.slice(0, n));

export function asoDoc(cfg) {
  const a = cfg.aso || {};
  const kwField = dedupeKeywords(a.keywords || []);
  const title = a.title || cap(`${cfg.name} — ${cfg.oneLiner}`, 30);
  const subtitle = cap(a.subtitle || cfg.oneLiner, 30);

  const warn = (label, s, n) =>
    s.length > n ? `  ⚠️ ${label} is ${s.length} chars (limit ${n}) — trim before pasting.` : "";

  return `# ${cfg.name} — App Store listing copy

Paste into App Store Connect → App Information / Version. Apple counts characters,
so the fields below are pre-fit. ASO is your real top-of-funnel — invest here first.

## Title  (≤30 chars)
${title}
${warn("Title", title, 30)}

## Subtitle  (≤30 chars)
${subtitle}
${warn("Subtitle", subtitle, 30)}

## Keywords field  (≤100 chars, comma-separated, NO spaces after commas, don't repeat the title words)
${kwField}
  (${kwField.length}/100 chars)

## Promotional text  (≤170 chars — editable any time without review)
${cap(a.promo || cfg.meta.ogDesc || cfg.meta.description, 170)}

## Description
${a.description || cfg.schemaDescription || cfg.meta.description}

## Screenshot captions (suggested order)
${(a.screenshots || ["Hero shot", "Core feature", "Privacy", "Free"]).map((s, i) => `${i + 1}. ${s}`).join("\n")}

## Notes
- Categories: ${(a.categories || []).join(", ") || "(set primary + secondary in App Store Connect)"}
- Localize the keyword field per storefront later — each locale adds 100 fresh chars.
- Ratings prompt: ask for a review only after a real "aha" moment (first letter / first dictation), never on launch.
`;
}

// Apple ignores spaces in the keyword field and de-dupes against the title,
// so we strip spaces and pack comma-separated up to 100 chars.
function dedupeKeywords(list) {
  const seen = new Set();
  const out = [];
  let len = 0;
  for (const raw of list) {
    const k = raw.trim().toLowerCase();
    if (!k || seen.has(k)) continue;
    const add = (out.length ? 1 : 0) + k.length;
    if (len + add > 100) break;
    out.push(k); seen.add(k); len += add;
  }
  return out.join(",");
}
