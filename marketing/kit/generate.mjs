#!/usr/bin/env node
// Marketing-kit generator.
//   node generate.mjs <product>        e.g. `node generate.mjs ori`
// Reads products/<product>.config.mjs and writes a complete, deployable
// marketing package to out/<product>/: landing page + sub-pages, og.png,
// sitemap.xml, robots.txt, ASO copy, launch drafts, and an SEO checklist.
import fs from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";
import { renderHome, renderSubpage, sitemap, robots } from "./lib/landing.mjs";
import { ogCardHtml, renderOg } from "./lib/og.mjs";
import { asoDoc } from "./lib/aso.mjs";
import { launchPosts } from "./lib/launch.mjs";
import { seoChecklist } from "./lib/checklist.mjs";
import { auditCopy, auditRatings } from "./lib/honesty.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = __dirname;

async function main() {
  const product = process.argv[2];
  if (!product) { console.error("usage: node generate.mjs <product>"); process.exit(1); }

  const cfgUrl = pathToUrl(path.join(ROOT, "products", `${product}.config.mjs`));
  const cfg = (await import(cfgUrl)).default;
  cfg.buildDate = cfg.buildDate || new Date().toISOString().slice(0, 10);

  // canonical URLs
  const homeUrl = `https://${cfg.domain}/`;
  cfg.canonical = homeUrl;
  cfg.homePage = { canonical: homeUrl, schema: ["software", "organization", "faq"], faqs: cfg.faq.faqs };
  const pages = cfg.pages || [];
  for (const p of pages) {
    p.canonical = `https://${cfg.domain}/${p.slug}/`;
    // FAQPage schema must mirror the visible FAQ — derive page.faqs from the
    // page's faq section so the JSON-LD and the <details> come from one source.
    if (p.schema?.includes("faq") && !p.faqs?.length) {
      const faqSec = (p.sections || []).find((s) => s.type === "faq");
      if (faqSec) p.faqs = faqSec.faqs;
    }
  }
  const urls = [homeUrl, ...pages.map((p) => p.canonical)];

  // ---- honesty gate (before writing anything) ----
  // Audit copy in coherent chunks so disclaimers stay with their negations.
  const chunks = [
    `${cfg.hero.h1} ${cfg.hero.sub} ${cfg.hero.fine}`, cfg.story.h2 + " " + cfg.story.p,
    cfg.showcase?.lede || "", ...cfg.friend.cards.map((c) => `${c.h3} ${c.p}`),
    ...cfg.how.beats.map((b) => `${b.h3} ${b.p}`), ...cfg.how.pillars.map((p) => `${p.h3} ${p.p}`),
    ...cfg.faq.faqs.map((f) => `${f.q} ${f.a}`),
    `${cfg.closing.h2} ${cfg.closing.p}`, cfg.meta.description, cfg.meta.ogDesc || "",
    cfg.schemaDescription || "", cfg.aso?.description || "", cfg.aso?.promo || "",
    ...flattenPages(pages)
  ];
  const hits = [...auditCopy(product, chunks, cfg), ...auditRatings(cfg)];
  if (hits.length) {
    console.error(`\n✗ honesty audit failed for "${product}":`);
    hits.forEach((h) => console.error("  - " + h));
    process.exit(2);
  }

  // ---- write package ----
  const out = path.join(ROOT, "out", product);
  await fs.rm(out, { recursive: true, force: true });
  await fs.mkdir(path.join(out, "launch"), { recursive: true });

  await write(path.join(out, "index.html"), renderHome(cfg));
  for (const p of pages) {
    await fs.mkdir(path.join(out, p.slug), { recursive: true });
    await write(path.join(out, p.slug, "index.html"), renderSubpage(cfg, p));
  }
  await write(path.join(out, "sitemap.xml"), sitemap(cfg, urls));
  await write(path.join(out, "robots.txt"), robots(cfg));
  await write(path.join(out, "aso.md"), asoDoc(cfg));
  const posts = launchPosts(cfg);
  await write(path.join(out, "launch", "producthunt.md"), posts.producthunt);
  await write(path.join(out, "launch", "showhn.md"), posts.showhn);
  await write(path.join(out, "launch", "reddit.md"), posts.reddit);
  await write(path.join(out, "seo-checklist.md"), seoChecklist(cfg, urls));

  // og card + image
  const cardPath = path.join(out, "og-card.html");
  await write(cardPath, ogCardHtml(cfg));
  try {
    await renderOg(cardPath, path.join(out, "og.png"));
    console.log("  • og.png rendered");
  } catch (e) {
    console.warn("  ! og.png skipped (playwright unavailable): " + e.message);
  }

  // copy screenshot assets if the config points at a shots dir
  if (cfg.assets?.shotsDir) {
    const src = path.resolve(ROOT, cfg.assets.shotsDir);
    try {
      await fs.cp(src, path.join(out, "shots"), { recursive: true });
      console.log("  • shots/ copied");
    } catch { console.warn("  ! shots dir not found: " + src); }
  }

  console.log(`\n✓ ${product} → ${path.relative(process.cwd(), out)} (${urls.length} page${urls.length > 1 ? "s" : ""})`);
}

async function write(p, s) { await fs.writeFile(p, s); }
function pathToUrl(p) { return "file://" + p; }

// pull every leaf copy string out of the sub-page configs for the honesty audit
function flattenPages(pages) {
  const out = [];
  for (const p of pages) {
    if (p.hero) out.push(`${p.hero.h1} ${p.hero.sub} ${p.hero.fine || ""}`);
    for (const sec of p.sections || []) {
      if (sec.type === "prose") out.push(sec.html.replace(/<[^>]+>/g, " "));
      if (sec.type === "faq") for (const f of sec.faqs) out.push(`${f.q} ${f.a}`);
      if (sec.type === "why") for (const c of sec.cards) out.push(`${c.h3} ${c.p}`);
    }
    if (p.closing) out.push(`${p.closing.h2} ${p.closing.p}`);
  }
  return out;
}

main().catch((e) => { console.error(e); process.exit(1); });
