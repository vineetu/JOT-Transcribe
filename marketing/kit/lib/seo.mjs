// <head> SEO/AEO block (meta + canonical + robots + OG/Twitter + JSON-LD),
// plus sitemap.xml and robots.txt. Mirrors what was hand-written for Ori.
import { softwareApplicationLD, organizationLD, faqPageLD } from "./schema.mjs";

const esc = (s = "") => String(s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// Build the <head> for any page (home or a sub-page). `page` carries per-URL
// overrides (canonical, title, description, og image, and which JSON-LD to emit).
export function head(cfg, page) {
  const canonical = page.canonical;
  const title = page.title || cfg.meta.title;
  const desc = page.description || cfg.meta.description;
  const ogTitle = page.ogTitle || cfg.meta.ogTitle || title;
  const ogDesc = page.ogDesc || cfg.meta.ogDesc || desc;
  const ogImage = `https://${cfg.domain}/${page.ogImage || "og.png"}`;
  const twDesc = page.twitterDesc || cfg.meta.twitterDesc || ogDesc;

  const ld = [];
  if (page.schema?.includes("software")) ld.push(softwareApplicationLD({ ...cfg, canonical }));
  if (page.schema?.includes("organization")) ld.push(organizationLD(cfg));
  if (page.schema?.includes("faq") && page.faqs?.length) ld.push(faqPageLD(page.faqs));

  return `<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(title)}</title>${cfg.verification?.gscTag ? `
<meta name="google-site-verification" content="${esc(cfg.verification.gscTag)}" />` : ""}${cfg.verification?.bingTag ? `
<meta name="msvalidate.01" content="${esc(cfg.verification.bingTag)}" />` : ""}
<meta name="description" content="${esc(desc)}" />
<link rel="canonical" href="${esc(canonical)}" />
<meta name="robots" content="index,follow" />

<meta property="og:type" content="website" />
<meta property="og:site_name" content="${esc(cfg.name)}" />
<meta property="og:url" content="${esc(canonical)}" />
<meta property="og:title" content="${esc(ogTitle)}" />
<meta property="og:description" content="${esc(ogDesc)}" />
<meta property="og:image" content="${esc(ogImage)}" />
<meta name="twitter:card" content="summary_large_image" />
<meta name="twitter:title" content="${esc(ogTitle)}" />
<meta name="twitter:description" content="${esc(twDesc)}" />
<meta name="twitter:image" content="${esc(ogImage)}" />
${ld.map((b) => `<script type="application/ld+json">\n${b}\n</script>`).join("\n")}${cfg.verification?.goatcounter ? `
<script data-goatcounter="https://${esc(cfg.verification.goatcounter)}.goatcounter.com/count" async src="//gc.zgo.at/count.js"></script>` : ""}`;
}

export function sitemap(cfg, urls) {
  const today = cfg.buildDate || "2026-06-23";
  const body = urls.map((u) =>
    `  <url><loc>${u}</loc><lastmod>${today}</lastmod></url>`).join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${body}\n</urlset>\n`;
}

export function robots(cfg) {
  return `User-agent: *\nAllow: /\nSitemap: https://${cfg.domain}/sitemap.xml\n`;
}
