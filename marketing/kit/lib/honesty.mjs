// Honesty guard — mirrors the intent of the repo's scripts/audit-honesty.mjs.
// Refuses to ship marketing that sells the product as "AI", makes a clinical /
// medical / diagnostic CLAIM, or shows star ratings that weren't supplied as
// real data.
//
// Copy is audited in coherent chunks (a whole FAQ q+a, a whole card) so an
// honest DISCLAIMER — "Is Ori therapy? No. It's not a medical tool and never
// makes a clinical claim." — is recognised as a denial, not a claim. A chunk is
// cleared for a flagged term if it also contains a negation, or if the config
// whitelists the term via `cfg.honesty.allow`.

const CLINICAL = [
  "diagnose", "diagnosis", "treatment", "cure", "therapy", "therapeutic",
  "clinically proven", "medical", "disorder", "prescribe"
];
const AI_HYPE = [
  "powered by ai", "ai-powered", "ai powered", "our ai", "artificial intelligence",
  "ai assistant", "ai journal", "ai friend", "ai companion"
];
const NEG = /\b(not|never|isn't|no|without|nothing|won't|doesn't|don't|aren't)\b/;

export function auditCopy(name, chunks, cfg) {
  const allow = (cfg.honesty?.allow || []).map((s) => s.toLowerCase());
  const hits = [];
  for (const raw of chunks) {
    const chunk = String(raw).toLowerCase();
    const cleared = NEG.test(chunk);
    const flag = (terms, kind) => {
      for (const t of terms) {
        if (!chunk.includes(t)) continue;
        if (allow.some((a) => a.includes(t) || t.includes(a))) continue;
        if (cleared) continue; // disclaimer / denial in same chunk
        hits.push(`${kind}: "${t}" — “${trim(raw)}”`);
      }
    };
    flag(CLINICAL, "clinical-claim");
    flag(AI_HYPE, "ai-hype");
  }
  return hits;
}

export function auditRatings(cfg) {
  return cfg.aggregateRating && !cfg.aggregateRating.real
    ? ["aggregateRating present without { real: true } — refusing to emit unverified stars."]
    : [];
}

const trim = (s) => { s = String(s).replace(/\s+/g, " ").trim(); return s.length > 90 ? s.slice(0, 90) + "…" : s; };
