// Social share card (1200×630 og.png) — what the link looks like when shared.
// Parameterized from the og-card.html Ori already had. Rendered with playwright,
// resolved from website/node_modules so the kit needs no deps of its own.
import { fileURLToPath, pathToFileURL } from "url";
import path from "path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export function ogCardHtml(cfg) {
  const o = cfg.og || {};
  const b = cfg.brand;
  const lk = b.lockup;
  const lock = lk.markPaths
    ? `<span class="lock">${lk.pre}<span class="r">${lk.mark}<span class="mk"><svg viewBox="0 0 120 120" fill="none"><g stroke="${o.markStroke || b.sage}" stroke-width="8" stroke-linecap="round" stroke-linejoin="round">${lk.markPaths.map((d) => `<path d="${d}"/>`).join("")}</g></svg></span></span>${lk.post}</span>`
    : `<span class="lock">${lk.plain}</span>`;
  return `<!doctype html><html><head><meta charset="utf-8"><style>
  :root{--serif:${b.serif};}
  *{margin:0;padding:0;box-sizing:border-box;}
  body{width:1200px;height:630px;overflow:hidden;}
  .card{width:1200px;height:630px;position:relative;display:flex;flex-direction:column;align-items:center;justify-content:center;
    background:radial-gradient(120% 80% at 50% 8%,${o.bgTop || "#161D12"},${o.bgBot || "#0A0D08"} 70%);color:${b.ink};}
  .lock{position:relative;font-family:var(--serif);font-size:128px;letter-spacing:-.015em;line-height:.9;}
  .lock .r{position:relative;}
  .lock .mk{position:absolute;left:50%;transform:translateX(-50%);bottom:.875em;}
  .lock .mk svg{display:block;width:.5em;height:.5em;}
  .tag{font-family:var(--serif);font-size:34px;color:${b.ink};margin-top:34px;letter-spacing:-.01em;}
  .sub{font-family:var(--serif);font-style:italic;font-size:22px;color:${b.sage};margin-top:16px;}
</style></head><body>
  <div class="card">
    ${lock}
    <div class="tag">${o.tag || cfg.oneLiner}</div>
    <div class="sub">${o.sub || ""}</div>
  </div>
</body></html>`;
}

async function loadPlaywright() {
  try { return (await import("playwright")).default || (await import("playwright")); }
  catch {
    const p = pathToFileURL(path.join(__dirname, "../../website/node_modules/playwright/index.js")).href;
    const m = await import(p);
    return m.default || m;
  }
}

export async function renderOg(cardHtmlPath, outPath) {
  const playwright = await loadPlaywright();
  const browser = await playwright.chromium.launch({ headless: true });
  const page = await browser.newPage({ deviceScaleFactor: 1 });
  await page.setViewportSize({ width: 1200, height: 630 });
  await page.goto(pathToFileURL(cardHtmlPath).href, { waitUntil: "networkidle" });
  await page.waitForTimeout(300);
  await page.screenshot({ path: outPath });
  await browser.close();
}
