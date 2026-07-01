// Assembles the landing page (and sub-pages) from a product config.
// Structure is ported 1:1 from Ori's website/brand/landing.html so the
// generated Ori homepage renders identically to the live one.
import { css } from "./css.mjs";
import { head, sitemap, robots } from "./seo.mjs";

// ---- shared pieces -------------------------------------------------------
function lockEl(lk, tag, attrs = "") {
  let inner;
  if (lk.markPaths) {
    const paths = lk.markPaths.map((d) => `<path d="${d}"/>`).join("");
    inner = `${lk.pre}<span class="r">${lk.mark}<span class="mk"><svg viewBox="0 0 120 120" fill="none"><g stroke-width="${lk.strokeWidth || 8}" stroke-linecap="round" stroke-linejoin="round">${paths}</g></svg></span></span>${lk.post}`;
  } else {
    inner = lk.plain;
  }
  const a = attrs ? " " + attrs : "";
  return `<${tag} class="lock"${a}>${inner}</${tag}>`;
}

function navEl(cfg) {
  const items = cfg.nav.links.map((l) => `    <a href="${l.href}">${l.label}</a>`);
  // GitHub repo link — an octocat mark pinned to the right of every header. Its own
  // class (.nav-gh) is exempt from the mobile hide rule, so it stays visible on phones.
  if (cfg.nav.github) {
    items.push(`    <a href="${cfg.nav.github}" class="nav-gh" target="_blank" rel="noopener" aria-label="${cfg.name} on GitHub"><svg viewBox="0 0 16 16" width="20" height="20" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0016 8c0-4.42-3.58-8-8-8z"/></svg></a>`);
  }
  items.push(`    <a href="${cfg.nav.cta.href}" class="nav-cta">${cfg.nav.cta.label}</a>`);
  return `<nav><div class="wrap nav-in">
  ${lockEl(cfg.brand.lockup, "a", 'href="#top"')}
  <div class="nav-links">
${items.join("\n")}
  </div>
</div></nav>`;
}

function footerEl(cfg) {
  const links = cfg.footer.links.map((l) => `<a href="${l.href}">${l.label}</a>`).join("");
  const crisis = cfg.footer.crisis
    ? `\n  <div class="foot-crisis">${cfg.footer.crisis.text} <a href="${cfg.footer.crisis.href}">${cfg.footer.crisis.linkLabel}</a></div>`
    : "";
  // Cross-link every content page from the footer of every page — kills orphan
  // pages so crawlers (and people) can reach each surface from anywhere.
  const explore = cfg.footer.explore?.length
    ? `\n  <nav class="foot-explore" aria-label="Explore Ori">${cfg.footer.explore
        .map((l) => `<a href="${l.href}">${l.label}</a>`).join("")}</nav>`
    : "";
  return `<footer><div class="wrap foot-in">
  ${lockEl(cfg.brand.lockup, "span")}${explore}
  <div class="foot-links">${links}</div>${crisis}
</div></footer>`;
}

function closingEl(cfg, c) {
  return `<section class="closing" id="get"><div class="wrap">
  ${lockEl(cfg.brand.lockup, "span")}
  <h2>${c.h2}</h2>
  <p>${c.p}</p>
  <a class="btn" href="${c.cta.href}">${c.cta.label}</a>
</div></section>`;
}

function faqEl(f) {
  const items = f.faqs.map((q, i) =>
    `    <details class="faq"${i === 0 ? " open" : ""}><summary>${q.q}</summary><div class="a">${q.a}</div></details>`
  ).join("\n");
  return `<section class="band faq-band" id="faq"><div class="wrap">
  <div class="kick">${f.kicker}</div>
  <h2>${f.h2}</h2>
  <div class="faqwrap">
${items}
  </div>
</div></section>`;
}

// hero typewriter — letterLines come in via JSON.stringify so escape sequences
// (the \n\n line breaks) are emitted correctly without being interpreted here.
function heroScript(lines) {
  return `<script>
  const LINES=${JSON.stringify(lines)};
  const el=document.getElementById('letter');
  const cursor=document.createElement('span');cursor.className='cursor';
  const reduce=window.matchMedia&&window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  function type(s,ref){return new Promise(res=>{const h=document.createElement('span');if(ref)h.className='ref';el.insertBefore(h,cursor);let i=0;(function tick(){if(i>=s.length){res();return;}const c=s[i++];h.appendChild(document.createTextNode(c));const extra=/[.,—:]/.test(c)?120:0;setTimeout(tick,30+extra+Math.random()*16);})();});}
  (async function(){el.appendChild(cursor);if(reduce){el.textContent=LINES.map(l=>l.t).join('');cursor.remove();return;}await new Promise(r=>setTimeout(r,700));for(const ln of LINES){await type(ln.t,ln.ref);await new Promise(r=>setTimeout(r,160));}setTimeout(()=>cursor.remove(),600);})();
</script>`;
}

function shell(cfg, page, bodyInner, scripts = "") {
  return `<!doctype html>
<html lang="${cfg.lang || "en"}">
<head>
${head(cfg, page)}
<style>${css(cfg.brand)}</style>
</head>
<body>

${navEl(cfg)}
${bodyInner}
${signupEl(cfg)}
${footerEl(cfg)}
${signupScript(cfg)}
${scripts}
</body>
</html>`;
}

// Opt-in email capture — posts to the feedback endpoint (version=waitlist).
// Rendered on every generated page when cfg.signup is set.
function signupEl(cfg) {
  const s = cfg.signup; if (!s) return "";
  return `<section class="ori-signup" id="stay"><div class="sgwrap">
  <h2>${s.heading}</h2>
  <p>${s.sub}</p>
  <form id="oriSignup" novalidate>
    <input type="email" id="oriEmail" placeholder="${s.placeholder}" autocomplete="email" required aria-label="Your email">
    <button type="submit">${s.button}</button>
  </form>
  <div id="oriSignupMsg" class="msg" role="status"></div>
</div></section>`;
}
function signupScript(cfg) {
  const s = cfg.signup; if (!s) return "";
  return `<script>
(function(){var f=document.getElementById('oriSignup');if(!f)return;f.addEventListener('submit',function(e){e.preventDefault();var em=document.getElementById('oriEmail').value.trim();var m=document.getElementById('oriSignupMsg');if(!/^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/.test(em)){m.style.color='#CBA85B';m.textContent='Please enter a valid email.';return;}m.style.color='#7C8070';m.textContent='Saving…';fetch('${s.endpoint}',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({platform:'web',version:'waitlist',message:em})}).then(function(r){if(r.ok){m.style.color='#A8C58B';m.textContent="You're in — thank you. 🌿";f.reset();}else{m.style.color='#CBA85B';m.textContent='That did not save — please try again later.';}}).catch(function(){m.style.color='#CBA85B';m.textContent='That did not save — please try again later.';});});})();
</script>`;
}

// ---- home ----------------------------------------------------------------
export function renderHome(cfg) {
  const h = cfg.hero, s = cfg.story, sc = cfg.showcase, fr = cfg.friend, how = cfg.how;
  const cards = fr.cards.map((c) =>
    `    <div class="fcard"><h3>${c.h3}</h3><p>${c.p}</p></div>`).join("\n");
  const beats = how.beats.map((b) =>
    `    <div class="beat"><div class="when">${b.when}</div><h3>${b.h3}</h3><p>${b.p}</p></div>`).join("\n");
  const pillars = how.pillars.map((p) =>
    `    <div class="pillar"><h3>${p.h3}</h3><p>${p.p}</p></div>`).join("\n");

  // Showcase (the layered phone fan) only renders if the product ships screenshots.
  const showcaseBlock = (sc && sc.shots?.length) ? `

<!-- SHOWCASE -->
<section class="showcase" id="features"><div class="wrap">
  <div class="kick">${sc.kicker}</div>
  <h2>${sc.h2}</h2>
  <p class="lede">${sc.lede}</p>
  <div class="stage">
${sc.shots.map((p) => `    <div class="shot ${p.cls}"><img src="${p.src}" alt="${p.alt}" loading="lazy"/></div>`).join("\n")}
  </div>
</div></section>` : "";

  const body = `
<!-- HERO -->
<header class="hero" id="top"><div class="wrap"><div class="hero-grid">
  <div class="hero-copy">
    <div class="hk">${h.kicker}</div>
    <h1>${h.h1}</h1>
    <p class="sub">${h.sub}</p>
    <div class="cta-row">
      <a class="btn primary" href="${h.ctaPrimary.href}">${h.ctaPrimary.label}</a>
      <a class="btn ghost" href="${h.ctaGhost.href}">${h.ctaGhost.label}</a>
    </div>
    <div class="fine">${h.fine}</div>
  </div>
  <div class="phone-stack">
    <div class="phone"><div class="scr">
      <div class="lt-date">${h.letter.date}</div>
      <div class="lt-sal">${h.letter.salutation}</div>
      <div class="lt-body" id="letter"></div>
    </div></div>
  </div>
</div></div></header>

<!-- STORY -->
<section class="story"><div class="wrap inner">
  <h2>${s.h2}</h2>
  <p>${s.p}</p>
</div></section>${showcaseBlock}

<!-- WHY -->
<section class="friend" id="friend"><div class="wrap">
  <div class="kick">${fr.kicker}</div>
  <h2>${fr.h2}</h2>
  <p class="lede">${fr.lede}</p>
  <div class="fgrid">
${cards}
  </div>
</div></section>

<!-- HOW -->
<section class="band" id="how"><div class="wrap">
  <div class="kick">${how.kicker}</div>
  <h2>${how.h2}</h2>
  <div class="beats">
${beats}
  </div>
  <div class="pillars" id="honest">
${pillars}
  </div>
</div></section>

${faqEl(cfg.faq)}

${closingEl(cfg, cfg.closing)}`;

  return shell(cfg, { ...cfg.homePage }, body, heroScript(h.letter.lines));
}

// ---- sub-page (Oura, journal-prompts) ------------------------------------
// Lighter layout: nav + header + prose/FAQ sections + closing + footer.
export function renderSubpage(cfg, page) {
  const h = page.hero;
  const sections = (page.sections || []).map((sec) => {
    if (sec.type === "prose") {
      return `<section class="band content-band"><div class="wrap"><div class="prose">
${sec.html}
</div></div></section>`;
    }
    if (sec.type === "faq") {
      return faqEl({ kicker: sec.kicker, h2: sec.h2, faqs: sec.faqs });
    }
    if (sec.type === "why") {
      const cards = sec.cards.map((c) => `    <div class="fcard"><h3>${c.h3}</h3><p>${c.p}</p></div>`).join("\n");
      return `<section class="friend"><div class="wrap">
  <div class="kick">${sec.kicker}</div>
  <h2>${sec.h2}</h2>${sec.lede ? `\n  <p class="lede">${sec.lede}</p>` : ""}
  <div class="fgrid">
${cards}
  </div>
</div></section>`;
    }
    return "";
  }).join("\n\n");

  const header = `<header class="hero" id="top"><div class="wrap"><div class="hero-grid" style="grid-template-columns:1fr;text-align:center;">
  <div class="hero-copy" style="margin:0 auto;">
    <div class="hk" style="text-align:center;">${h.kicker}</div>
    <h1>${h.h1}</h1>
    <p class="sub" style="margin-left:auto;margin-right:auto;">${h.sub}</p>
    <div class="cta-row" style="justify-content:center;">
      <a class="btn primary" href="${h.ctaPrimary.href}">${h.ctaPrimary.label}</a>${h.ctaGhost ? `
      <a class="btn ghost" href="${h.ctaGhost.href}">${h.ctaGhost.label}</a>` : ""}
    </div>${h.fine ? `\n    <div class="fine" style="text-align:center;">${h.fine}</div>` : ""}
  </div>
</div></div></header>`;

  const body = `\n${header}\n\n${sections}\n\n${closingEl(cfg, page.closing || cfg.closing)}`;
  return shell(cfg, page, body);
}

export { sitemap, robots };
