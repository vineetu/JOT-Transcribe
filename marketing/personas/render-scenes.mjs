// Jot persona scenes — renders the five persona feed images (1080×1350 PNG)
// into out/ from self-contained HTML. Brand palette mirrors
// marketing/kit/products/jot.config.mjs (graphite + electric blue).
//
//   node render-scenes.mjs            # all five
//   node render-scenes.mjs professor  # one
//
// Design contract (why these blocks exist):
//   FEATURE  → the mechanic strip: ⌥ Space → speak → text at your cursor.
//   VALUE    → typed-vs-spoken contrast inside the persona's own app, with
//              REAL word counts computed from the on-image text (honest,
//              verifiable — never an invented speed/accuracy number).
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

// Each scene: hook, the persona's app window, and the value contrast —
// `typed` (what friction reduces you to) vs `spoken` (what Jot captures).
const SCENES = {
  professor: {
    hook: '40 essays. Feedback due Friday.',
    sub: 'Typed comments shrink. Spoken ones teach.',
    winTitle: 'Essay 12 of 40 — “The Green Revolution” · Pages',
    typed: 'Good point — expand your conclusion.',
    spoken: 'Your argument in section two is genuinely strong — you connect the irrigation data to policy in a way most of the class missed. Push the same rigor into your conclusion: right now it summarizes instead of answering the “so what.” Bring one counterexample and this is an A-range essay.',
    close: 'Feedback that sounds like you. Student work never leaves your Mac.',
  },
  developer: {
    hook: 'Standup in 2 minutes.',
    sub: 'The update you’d type isn’t the update you’d give.',
    winTitle: '#standup · Slack',
    typed: 'auth fix done, starting rotation. blocked on ops.',
    spoken: 'Yesterday: landed the auth-token refresh fix and got the flaky session test green. Today: starting the API-key rotation endpoint, PR up by four. Blocked: still need staging access from ops — pinged them again.',
    close: 'Free, open-source, on-device. Back to the code.',
  },
  writer: {
    hook: 'The blank page wins when you type at it.',
    sub: 'Talk the scene out. Edit with your hands later.',
    winTitle: 'chapter-three.pages — Draft',
    typed: 'Marta finds a letter. (deleted twice)',
    spoken: 'Marta finds the letter on a Tuesday, wedged behind the radiator like it had been waiting out the winter. She reads it twice standing up, then once more sitting down, because some sentences need a chair. The handwriting is her mother’s — but younger somehow, looser, the g’s still hopeful.',
    close: 'Draft out loud. Free, on-device — your words stay on your machine.',
  },
  student: {
    hook: 'It’s all still in your head. For about an hour.',
    sub: 'Explain it to yourself before it fades.',
    winTitle: 'BIO 201 — lecture recap · Notes',
    typed: 'krebs cycle → electrons → ATP. review later',
    spoken: 'Okay so the whole point of the Krebs cycle is stripping electrons off carbon — the carbons leave as CO2 and the electrons ride NADH to the transport chain. The chain is basically a dam: electrons flow down, protons get pumped up, and ATP synthase is the turbine at the bottom. Exam trick: count NADH per turn, it’s three.',
    close: 'Free. No account. Works offline in the library basement.',
  },
  meeting: {
    hook: 'A decision just happened.',
    sub: 'Capture it without breaking eye contact.',
    winTitle: 'Product sync — minutes · Notion',
    typed: 'ios later, sam checklist',
    spoken: 'Decided: we ship the iOS build one week after Mac, not same-day — App Store review risk is on us, not marketing. Sam owns the submission checklist by Thursday.',
    close: 'Still listening. Nothing left your Mac.',
  },
};

const words = (s) => s.replace(/<[^>]+>/g, '').trim().split(/\s+/).length;

function html(scene) {
  const tw = words(scene.typed);
  const sw = words(scene.spoken);
  return `<!doctype html><html><head><meta charset="utf-8"><style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { width:1080px; height:1350px; background:${B.night}; color:${B.ink};
         font-family:${B.meta}; display:flex; flex-direction:column; padding:64px 64px 52px; }
  h1 { font-family:${B.serif}; font-size:60px; line-height:1.12; font-weight:600; letter-spacing:-.01em; }
  .sub { color:${B.soft}; font-size:29px; margin-top:14px; }

  /* FEATURE — the mechanic, unmissable */
  .how { display:flex; align-items:center; gap:14px; margin-top:30px; }
  .chip { background:${B.panel}; border:1px solid ${B.line}; border-radius:12px;
          padding:12px 20px; font-size:25px; color:${B.ink}; }
  .chip b { color:${B.blue}; font-weight:600; }
  .arr { color:${B.faint}; font-size:26px; }

  .win { margin-top:auto; background:#F5F7FA; color:#10141A; border-radius:18px; overflow:hidden;
         box-shadow:0 30px 80px rgba(0,0,0,.55); flex:0 0 auto; display:flex; flex-direction:column; position:relative; }
  .bar { background:#E8ECF1; padding:15px 20px; display:flex; align-items:center; gap:8px; }
  .dot { width:14px; height:14px; border-radius:50%; }
  .ttl { margin-left:12px; color:#5B6573; font-size:21px; }
  .doc { padding:34px 44px 104px; font-size:27px; line-height:1.52; }

  /* VALUE — typed vs spoken, side by side in their real app */
  .tag { font-size:19px; letter-spacing:.12em; text-transform:uppercase; color:#8A93A0; margin-bottom:9px; }
  .tag b { color:#10141A; }
  .tag .n { color:${B.sageDk ?? '#2D6CCB'}; }
  .typed { color:#8A93A0; text-decoration:line-through; text-decoration-color:rgba(16,20,26,.35);
           text-decoration-thickness:2px; margin-bottom:26px; }
  .spoken { background:rgba(91,157,255,.13); border-left:5px solid ${B.blue}; padding:18px 22px;
            border-radius:6px; }
  .caret { display:inline-block; width:3px; height:29px; background:${B.blue}; margin-left:4px;
           vertical-align:text-bottom; }
  .pill { position:absolute; left:50%; transform:translateX(-50%); bottom:24px; background:#10141A;
          color:#EDF1F6; border-radius:999px; padding:13px 25px; font-size:23px; display:flex;
          align-items:center; gap:12px; box-shadow:0 10px 30px rgba(0,0,0,.35); }
  .pdot { width:14px; height:14px; border-radius:50%; background:${B.blue}; box-shadow:0 0 14px ${B.blue}; }

  .close { margin-top:auto; padding-top:38px; display:flex; justify-content:space-between; align-items:baseline; }
  .truth { font-size:28px; color:${B.soft}; max-width:740px; }
  .brand { font-size:25px; color:${B.faint}; white-space:nowrap; }
  .brand b { color:${B.ink}; font-weight:600; }
  </style></head><body>
    <h1>${scene.hook}</h1>
    <p class="sub">${scene.sub}</p>
    <div class="how">
      <span class="chip">press <b>⌥ Space</b></span><span class="arr">→</span>
      <span class="chip"><b>speak</b></span><span class="arr">→</span>
      <span class="chip">text lands <b>at your cursor</b></span>
    </div>
    <div class="win">
      <div class="bar">
        <span class="dot" style="background:#FF5F57"></span>
        <span class="dot" style="background:#FEBC2E"></span>
        <span class="dot" style="background:#28C840"></span>
        <span class="ttl">${scene.winTitle}</span>
      </div>
      <div class="doc">
        <p class="tag">What typing gets you · <b>${tw} words</b></p>
        <p class="typed">${scene.typed}</p>
        <p class="tag">What you actually had to say · <b class="n">${sw} words, spoken once</b></p>
        <p class="spoken">${scene.spoken}<span class="caret"></span></p>
      </div>
      <div class="pill"><span class="pdot"></span>Listening…</div>
    </div>
    <div class="close">
      <p class="truth">${scene.close}</p>
      <p class="brand"><b>Jot</b> · free · on-device · jot-transcribe.com</p>
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
