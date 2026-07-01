// JSON-LD builders. One FAQ array drives BOTH the visible <details> accordion
// and the FAQPage schema, so Google / answer engines cite the product's true
// answers instead of inventing them — and the two can never drift apart.

const j = (o) => JSON.stringify(o, null, 2);

export const softwareApplicationLD = (cfg) => j({
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: cfg.name,
  applicationCategory: cfg.aso?.schemaCategory || "LifestyleApplication",
  operatingSystem: cfg.operatingSystem || "iOS",
  description: cfg.schemaDescription || cfg.meta.description,
  url: cfg.canonical,
  // aggregateRating is intentionally omitted unless real ratings are supplied —
  // honesty.mjs blocks faked stars.
  ...(cfg.aggregateRating ? { aggregateRating: cfg.aggregateRating } : {}),
  offers: { "@type": "Offer", price: cfg.price ?? "0", priceCurrency: cfg.priceCurrency || "USD" }
});

export const organizationLD = (cfg) => j({
  "@context": "https://schema.org",
  "@type": "Organization",
  name: cfg.name,
  url: `https://${cfg.domain}/`,
  logo: `https://${cfg.domain}/${cfg.assets?.logo || "icon-512.png"}`
});

export const faqPageLD = (faqs) => j({
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: faqs.map((f) => ({
    "@type": "Question",
    name: f.q,
    acceptedAnswer: { "@type": "Answer", text: f.a }
  }))
});
