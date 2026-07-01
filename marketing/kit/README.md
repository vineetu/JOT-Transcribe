# marketing/kit — the marketing generator

A small, dependency-free Node generator that produces Jot's marketing surfaces from a
single config. Ported from the Ori marketing kit; driven here by `products/jot.config.mjs`.

## Run

```bash
node marketing/kit/generate.mjs jot
```

Output lands in `marketing/kit/out/jot/` (gitignored — it's a build artifact):

| File | What it is |
|------|-----------|
| `index.html` | The landing page (SEO + FAQ + SoftwareApplication JSON-LD baked in) |
| `sitemap.xml`, `robots.txt` | Crawl surfaces |
| `aso.md` | Paste-ready App Store title/subtitle/keywords/description |
| `launch/producthunt.md`, `launch/reddit.md`, `launch/showhn.md` | Launch drafts |
| `seo-checklist.md` | The off-page / indexing checklist |
| `og-card.html` | 1200×630 social card (render to PNG with Playwright if installed) |

## Edit the copy

Everything lives in **`products/jot.config.mjs`** — hero, story, FAQ, ASO, launch posts,
nav, footer. Change it there and re-run; nothing else needs editing.

## Honesty gate

`lib/honesty.mjs` runs at generate time and **fails the build** on unproven claims
(AI-hype, clinical/medical claims, fake ratings). Keep new copy true — every claim must
be something Jot actually does.

## Relationship to Mission Control

This generator produces the **public** marketing pages. The internal dashboard —
`../mission-control/index.html` — is the private command center (downloads, analytics,
growth channels, drafts). It reads live data from the `jamyc3/jot-marketing-data` feed.
Together they are the marketing deck.
