# Jot — marketing deck

Everything that markets Jot, in one place.

```
marketing/
├── kit/                 the generator — produces the public landing page, SEO, ASO,
│                        and launch drafts from products/jot.config.mjs  (run: node marketing/kit/generate.mjs jot)
├── mission-control/     the internal command center (index.html) — downloads, analytics,
│                        growth channels, drafts. Served at jot-transcribe.com/admin/.
│                        Reads live data from the jamyc3/jot-marketing-data feed.
├── distribution/        durable-channel playbooks (Homebrew, AlternativeTo, MacUpdate,
│                        communities, reddit) — the checklist items in Mission Control link here.
└── data/                the marketing data feed (downloads, App Store, snapshots, starter pack),
                         mirrored to jamyc3/jot-marketing-data for Mission Control to read.
```

## The two halves

- **Public** (`kit/`) — what the world sees. One config, honesty-gated, regenerated on demand.
- **Private** (`mission-control/`) — what you steer by. Live metrics + the daily plan.

The toolkit and Mission Control were consolidated here so the whole marketing operation
lives in the project repo (ported/adapted from the Ori marketing kit).

## Quick start

```bash
node marketing/kit/generate.mjs jot     # regenerate the public pages → kit/out/jot/
open marketing/mission-control/index.html   # open the dashboard (reads the live feed)
```
