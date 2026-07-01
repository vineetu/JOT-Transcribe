// The human-only steps: search-engine verification + submission, ASO paste,
// and the "add this only when it's real" notes. Generated per product so the
// URLs and tags are already filled in.

export function seoChecklist(cfg, urls) {
  const d = cfg.domain;
  return `# ${cfg.name} — SEO / discovery checklist

On-page is done by the generator. These are the steps a human must click through.

## 1. Google Search Console — ${cfg.verification?.gscTag ? "verified ✓" : "verify"}
${cfg.verification?.gscTag
  ? `- Tag already in <head> (\`${cfg.verification.gscTag.slice(0, 12)}…\`). Property is verified.`
  : `- Add a URL-prefix property for https://${d}/ and verify via the HTML tag, then set \`verification.gscTag\` in the config and redeploy.`}
- **Sitemaps → enter \`sitemap.xml\` → Submit.**
- **URL Inspection → paste each URL → Request Indexing:**
${urls.map((u) => `    - ${u}`).join("\n")}

## 2. Bing Webmaster Tools — ${cfg.verification?.bingTag ? "verified ✓" : "verify"}
Bing powers Copilot and part of ChatGPT search, so this widens answer-engine reach.
${cfg.verification?.bingTag
  ? `- \`msvalidate.01\` tag is in <head>. Submit \`sitemap.xml\` under Sitemaps.`
  : `- Easiest path: "Import from Google Search Console." Or add a site, copy the \`msvalidate.01\` content into \`verification.bingTag\`, redeploy, verify, then submit \`sitemap.xml\`.`}

## 3. ASO (App Store Connect) — the real top-of-funnel
- Paste \`aso.md\` fields (title / subtitle / keywords / description / promo).
- Upload screenshots in the captioned order.
- Add an in-app review prompt that fires only after a genuine "aha" moment.

## 4. Off-page (publish the \`launch/\` drafts)
- Product Hunt, Show HN, and the Reddit drafts. These backlinks are what lift Google rankings.
- Email the "best ${cfg.category || "journal"} apps" roundup authors to get ${cfg.name} added.

## 5. aggregateRating — ONLY when real
- Do **not** add star ratings to the SoftwareApplication schema until you have real
  App Store ratings. Then set \`aggregateRating: { real: true, ratingValue, ratingCount }\`
  in the config — the honesty guard blocks it otherwise.
`;
}
