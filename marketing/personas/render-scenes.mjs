// Jot persona scenes — renders the five persona feed images (1080×1350 PNG)
// into out/ from self-contained HTML. Brand palette mirrors
// marketing/kit/products/jot.config.mjs (graphite + electric blue).
//
//   node render-scenes.mjs            # all five
//   node render-scenes.mjs professor  # one
//
// Needs playwright resolvable from this directory (symlink or npm i playwright).
import { chromium } from 'playwright';
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = dirname(fileURLToPath(import.meta.url));

const B = {
  night: '#0E1116', panel: '#161B22', ink: '#EDF1F6', soft: '#B7C0CC', faint: '#6E7A88',
  blue: '#5B9DFF', line: 'rgba(91,157,255,.16)',
  serif: "ui-serif,'New York','Iowan Old Style',Georgia,serif",
  meta: "-apple-system,BlinkMacSystemFont,system-ui,sans-serif",
};

// Each scene: hook (serif headline), app window (title + persona content),
// the freshly-landed spoken text (highlighted, cursor at its end), honest close.
const SCENES = {
  professor: {
    hook: '40 essays. Feedback due Friday.',
    sub: 'Say what you’d tell them in office hours.',
    winTitle: 'Essay 12 of 40 — “The Green Revolution” · Pages',
    body: [
      { t: 'ctx', html: '…irrigation reforms accelerated yield, but the essay treats adoption as uniform across regions.' },
      { t: 'label', html: 'Feedback' },
      { t: 'spoken', html: 'Your argument in section two is genuinely strong — you connect the irrigation data to policy in a way most of the class missed. Push the same rigor into your conclusion: right now it summarizes instead of answering the “so what.” Bring one counterexample and this is an A-range essay.' },
    ],
    close: 'Feedback that sounds like you. Student work never leaves your Mac.',
  },
  developer: {
    hook: 'Standup in 2 minutes.',
    sub: 'Say what you did, what’s next, what’s blocked.',
    winTitle: '#standup · Slack',
    body: [
      { t: 'ctx', html: '<b>priya</b> · 9:41 — shipped the retry queue, starting on the webhook signatures today, no blockers' },
      { t: 'spoken', html: '<b>you</b> · 9:42 — Yesterday: landed the auth-token refresh fix and got the flaky session test green. Today: starting the API-key rotation endpoint, PR up by four. Blocked: still need staging access from ops — pinged them again.' },
    ],
    close: 'Free, open-source, on-device. Back to the code.',
  },
  writer: {
    hook: 'The blank page wins when you type at it.',
    sub: 'Talk the scene out instead. Edit with your hands later.',
    winTitle: 'chapter-three.pages — Draft',
    body: [
      { t: 'spoken', html: 'Marta finds the letter on a Tuesday, wedged behind the radiator like it had been waiting out the winter. She reads it twice standing up, then once more sitting down, because some sentences need a chair. The handwriting is her mother’s — but younger somehow, looser, the g’s still hopeful.' },
    ],
    close: 'Draft out loud. Free, on-device — your words stay on your machine.',
  },
  student: {
    hook: 'It’s all still in your head. For about an hour.',
    sub: 'Explain it to yourself before it fades.',
    winTitle: 'BIO 201 — lecture recap · Notes',
    body: [
      { t: 'ctx', html: 'Oct 12 · Krebs cycle, electron transport chain' },
      { t: 'spoken', html: 'Okay so the whole point of the Krebs cycle is stripping electrons off carbon — the carbons leave as CO2 and the electrons ride NADH to the transport chain. The chain is basically a dam: electrons flow down, protons get pumped up, and ATP synthase is the turbine at the bottom. Exam trick: count NADH per turn, it’s three.' },
    ],
    close: 'Free. No account. Works offline in the library basement.',
  },
  meeting: {
    hook: 'A decision just happened.',
    sub: 'One hotkey. Say it without breaking eye contact.',
    winTitle: 'Product sync — minutes · Notion',
    body: [
      { t: 'ctx', html: '• Launch date holds — Nov 4<br>• Pricing page copy → Dana, Friday' },
      { t: 'spoken', html: '• Decided: we ship the iOS build one week after Mac, not same-day — App Store review risk is on us, not marketing. Sam owns the submission checklist by Thursday.' },
    ],
    close: 'Still listening. Nothing left your Mac.',
  },
};

function html(scene) {
  const rows = scene.body.map((r) => {
    if (r.t === 'ctx') return `<p class="ctx">${r.html}</p>`;
    if (r.t === 'label') return `<p class="label">${r.html}</p>`;
    return `<p class="spoken">${r.html}<span class="caret"></span></p>`;
  }).join('\n');
  return `<!doctype html><html><head><meta charset="utf-8"><style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { width:1080px; height:1350px; background:${B.night}; color:${B.ink};
         font-family:${B.meta}; display:flex; flex-direction:column; padding:72px 64px 56px; }
  .kbd { display:inline-block; border:1px solid ${B.line}; border-radius:10px; padding:6px 14px;
         color:${B.blue}; font-size:26px; letter-spacing:.06em; margin-bottom:28px; background:${B.panel}; }
  h1 { font-family:${B.serif}; font-size:64px; line-height:1.12; font-weight:600; letter-spacing:-.01em; }
  .sub { color:${B.soft}; font-size:30px; margin-top:18px; }
  .win { margin-top:auto; background:#F5F7FA; color:#10141A; border-radius:18px; overflow:hidden;
         box-shadow:0 30px 80px rgba(0,0,0,.55); flex:0 0 auto; display:flex; flex-direction:column; position:relative; }
  .bar { background:#E8ECF1; padding:16px 20px; display:flex; align-items:center; gap:8px; }
  .dot { width:14px; height:14px; border-radius:50%; }
  .ttl { margin-left:12px; color:#5B6573; font-size:22px; }
  .doc { padding:40px 48px 120px; font-size:28px; line-height:1.55; overflow:hidden; }
  .ctx { color:#5B6573; margin-bottom:26px; }
  .label { font-size:20px; letter-spacing:.12em; text-transform:uppercase; color:#5B6573; margin-bottom:10px; }
  .spoken { background:rgba(91,157,255,.13); border-left:5px solid ${B.blue}; padding:18px 22px;
            border-radius:6px; }
  .caret { display:inline-block; width:3px; height:30px; background:${B.blue}; margin-left:4px;
           vertical-align:text-bottom; }
  .pill { position:absolute; left:50%; transform:translateX(-50%); bottom:26px; background:#10141A;
          color:#EDF1F6; border-radius:999px; padding:14px 26px; font-size:24px; display:flex;
          align-items:center; gap:12px; box-shadow:0 10px 30px rgba(0,0,0,.35); }
  .pdot { width:14px; height:14px; border-radius:50%; background:${B.blue};
          box-shadow:0 0 14px ${B.blue}; }
  .close { margin-top:auto; padding-top:44px; display:flex; justify-content:space-between; align-items:baseline; }
  .truth { font-size:30px; color:${B.soft}; max-width:760px; }
  .brand { font-size:26px; color:${B.faint}; white-space:nowrap; }
  .brand b { color:${B.ink}; font-weight:600; }
  </style></head><body>
    <div><span class="kbd">⌥ Space</span></div>
    <h1>${scene.hook}</h1>
    <p class="sub">${scene.sub}</p>
    <div class="win">
      <div class="bar">
        <span class="dot" style="background:#FF5F57"></span>
        <span class="dot" style="background:#FEBC2E"></span>
        <span class="dot" style="background:#28C840"></span>
        <span class="ttl">${scene.winTitle}</span>
      </div>
      <div class="doc">${rows}</div>
      <div class="pill"><span class="pdot"></span>Listening…</div>
    </div>
    <div class="close">
      <p class="truth">${scene.close}</p>
      <p class="brand"><b>Jot</b> · jot-transcribe.com</p>
    </div>
  </body></html>`;
}

const only = process.argv[2];
const outDir = join(ROOT, 'out');
mkdirSync(outDir, { recursive: true });
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1080, height: 1350 } });
for (const [name, scene] of Object.entries(SCENES)) {
  if (only && name !== only) continue;
  const f = join(outDir, `persona-${name}.html`);
  writeFileSync(f, html(scene));
  await page.goto('file://' + f);
  await page.screenshot({ path: join(outDir, `persona-${name}.png`) });
  console.log('rendered', `persona-${name}.png`);
}
await browser.close();
