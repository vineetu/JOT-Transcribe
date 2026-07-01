// The landing-page stylesheet, ported verbatim from Ori's hand-tuned
// website/brand/landing.html — with every product-specific colour pulled up
// into a CSS variable so a second product (jot, …) can re-theme it from config.
// Renders identically to the live Ori page when fed Ori's palette.

export const css = (b) => `
  :root{
    --night:${b.night}; --night2:${b.night2}; --panel:${b.panel}; --ink:${b.ink}; --soft:${b.soft}; --faint:${b.faint};
    --sage:${b.sage}; --amber:${b.amber}; --clay:${b.clay}; --line:${b.line};
    --screen:${b.screen}; --paper:${b.paper}; --paperHi:${b.paperHi}; --pink:${b.pink}; --pmuted:${b.pmuted}; --phair:${b.phair};
    --forest:${b.forest}; --sageDk:${b.sageDk};
    --ctaInk:${b.ctaInk}; --bezel:${b.bezel};
    --glowTriple:${b.glowTriple}; --glow2Triple:${b.glow2Triple}; --amberGlowTriple:${b.amberGlowTriple};
    --heroTop:${b.heroTop}; --heroMid:${b.heroMid}; --heroBot:${b.heroBot};
    --showTop:${b.showTop}; --showMid:${b.showMid}; --friendMid:${b.friendMid};
    --serif:${b.serif}; --meta:${b.meta};
  }
  *{margin:0;padding:0;box-sizing:border-box;}
  html{scroll-behavior:smooth;}
  body{font-family:var(--meta);background:var(--night);color:var(--ink);-webkit-font-smoothing:antialiased;line-height:1.5;}
  .wrap{max-width:1120px;margin:0 auto;padding:0 32px;}
  a{color:inherit;text-decoration:none;}
  .kick{font-family:var(--serif);font-style:italic;font-size:16px;color:var(--sage);text-align:center;margin-bottom:14px;}
  .lock{position:relative;display:inline-block;font-family:var(--serif);font-weight:400;letter-spacing:-.015em;line-height:.9;}
  .lock .r{position:relative;}
  .lock .mk{position:absolute;left:50%;transform:translateX(-50%);bottom:.875em;}
  .lock .mk svg{display:block;width:.5em;height:.5em;}

  /* NAV */
  nav{position:sticky;top:0;z-index:40;background:rgba(14,18,13,.72);backdrop-filter:saturate(1.1) blur(12px);border-bottom:1px solid rgba(255,255,255,.06);}
  .nav-in{display:flex;align-items:center;justify-content:space-between;height:66px;}
  nav .lock{font-size:25px;color:var(--ink);}nav .lock .mk svg g{stroke:var(--sage);}
  .nav-links{display:flex;gap:30px;align-items:center;}
  .nav-links a{font-family:var(--meta);font-size:14px;color:var(--soft);transition:color .15s;}
  .nav-links a:hover{color:var(--ink);}
  .nav-links a.nav-cta{font-family:var(--meta);font-size:13.5px;font-weight:600;color:var(--ctaInk);background:var(--sage);padding:10px 18px;border-radius:999px;}
  .nav-links a.nav-cta:hover{color:var(--ctaInk);}
  .nav-gh{display:inline-flex;align-items:center;color:var(--soft);}
  .nav-gh:hover{color:var(--ink);}
  .nav-gh svg{display:block;width:20px;height:20px;}
  @media (max-width:720px){.nav-links a:not(.nav-cta):not(.nav-gh){display:none;}}

  /* HERO */
  .hero{position:relative;overflow:hidden;background:linear-gradient(165deg,var(--heroTop),var(--heroMid) 55%,var(--heroBot));}
  .hero::before{content:'';position:absolute;inset:-25%;pointer-events:none;
    background:radial-gradient(40% 40% at 22% 24%,rgba(var(--glow2Triple),.14),transparent 70%),radial-gradient(46% 46% at 84% 72%,rgba(var(--amberGlowTriple),.10),transparent 72%);
    animation:drift 26s ease-in-out infinite alternate;}
  @keyframes drift{from{transform:translate(0,0) scale(1);}to{transform:translate(-5%,3%) scale(1.12);}}
  .hero-grid{position:relative;z-index:2;display:grid;grid-template-columns:1.08fr .92fr;gap:50px;align-items:center;padding:84px 0 100px;}
  .hk{font-family:var(--serif);font-style:italic;font-size:16px;color:var(--sage);margin-bottom:18px;}
  .hero-copy h1{font-family:var(--serif);font-weight:400;font-size:clamp(40px,5.4vw,66px);line-height:1.04;letter-spacing:-.02em;color:var(--ink);margin-bottom:22px;}
  .hero-copy p.sub{font-family:var(--serif);font-size:clamp(17px,2.1vw,21px);line-height:1.62;color:var(--soft);max-width:42ch;margin-bottom:34px;}
  .cta-row{display:flex;gap:14px;align-items:center;flex-wrap:wrap;}
  .btn{font-family:var(--meta);font-size:15px;font-weight:600;padding:14px 28px;border-radius:999px;}
  .btn.primary{background:var(--sage);color:var(--ctaInk);}
  .btn.ghost{border:1px solid rgba(241,236,223,.22);color:var(--soft);}
  .hero-copy .fine{margin-top:22px;font-family:var(--serif);font-style:italic;font-size:14px;color:var(--faint);}
  .trust{margin-top:26px;display:flex;flex-wrap:wrap;gap:9px;}
  .trust span{font-family:var(--meta);font-size:12px;color:var(--soft);background:rgba(var(--glowTriple),.08);border:1px solid var(--line);border-radius:999px;padding:7px 13px;}
  @media (max-width:880px){.trust{justify-content:center;}}

  /* hero phone */
  .phone-stack{position:relative;display:flex;justify-content:center;align-items:center;}
  .phone-stack::before{content:'';position:absolute;width:300px;height:300px;border-radius:50%;background:radial-gradient(closest-side,rgba(var(--glowTriple),.16),transparent);filter:blur(20px);}
  .phone{position:relative;border-radius:42px;padding:9px;background:var(--bezel);box-shadow:0 44px 100px rgba(0,0,0,.62),0 0 80px rgba(var(--glowTriple),.10),0 0 0 1px rgba(var(--glowTriple),.16);}
  .phone .scr{width:286px;height:600px;border-radius:34px;overflow:hidden;background:radial-gradient(120% 70% at 50% 8%,var(--showMid),var(--heroTop) 70%);padding:34px 26px;display:flex;flex-direction:column;}
  .lt-date{font-family:var(--serif);font-style:italic;font-size:13px;color:var(--faint);text-align:center;margin-bottom:8px;}
  .lt-sal{font-family:var(--serif);font-size:27px;color:var(--ink);text-align:center;margin-bottom:16px;}
  .lt-body{font-family:var(--serif);font-size:16.5px;line-height:1.72;color:var(--ink);white-space:pre-wrap;text-wrap:pretty;flex:1;}
  .lt-body .ref{color:var(--sage);text-decoration:underline;text-decoration-style:dotted;text-underline-offset:3px;}
  .cursor{display:inline-block;width:2px;height:1.02em;background:var(--sage);vertical-align:-2px;animation:blink 1.05s steps(1) infinite;}
  @keyframes blink{50%{opacity:0;}}

  /* STORY band */
  .story{background:var(--night);text-align:center;padding:130px 0;border-top:1px solid rgba(255,255,255,.05);position:relative;overflow:hidden;}
  .story::before{content:'';position:absolute;inset:0;background:radial-gradient(60% 50% at 50% 30%,rgba(var(--glow2Triple),.07),transparent 70%);}
  .story .inner{position:relative;}
  .story h2{font-family:var(--serif);font-weight:400;font-size:clamp(32px,5.4vw,58px);letter-spacing:-.02em;line-height:1.08;max-width:16ch;margin:0 auto;color:var(--ink);}
  .story h2 .accent{color:var(--sage);font-style:italic;}
  .story p{font-family:var(--serif);font-size:clamp(17px,2.2vw,21px);color:var(--soft);max-width:46ch;margin:28px auto 0;line-height:1.65;}

  /* SHOWCASE */
  .showcase{background:linear-gradient(180deg,var(--showTop),var(--showMid) 50%,var(--showTop));padding:104px 0 120px;text-align:center;border-top:1px solid rgba(255,255,255,.05);}
  .showcase h2{font-family:var(--serif);font-weight:400;font-size:clamp(28px,4.2vw,44px);color:var(--ink);letter-spacing:-.01em;margin-bottom:10px;}
  .showcase .lede{font-family:var(--serif);font-size:17px;color:var(--soft);max-width:42ch;margin:0 auto 30px;}
  .stage{position:relative;height:600px;display:flex;justify-content:center;align-items:center;margin-top:18px;}
  .stage::before{content:'';position:absolute;width:520px;height:380px;border-radius:50%;background:radial-gradient(closest-side,rgba(var(--glowTriple),.14),transparent);filter:blur(30px);}
  .shot{position:absolute;border-radius:34px;padding:7px;background:var(--bezel);transition:transform .4s ease;}
  .shot img{display:block;width:208px;border-radius:28px;}
  .shot.left{transform:translateX(-228px) translateY(26px) rotate(-7deg) scale(.9);z-index:1;box-shadow:0 30px 70px rgba(0,0,0,.5);}
  .shot.right{transform:translateX(228px) translateY(26px) rotate(7deg) scale(.9);z-index:1;box-shadow:0 30px 70px rgba(0,0,0,.5);}
  .shot.center{z-index:3;box-shadow:0 46px 100px rgba(0,0,0,.62),0 0 70px rgba(var(--glowTriple),.12),0 0 0 1px rgba(var(--glowTriple),.16);}
  .shot.center img{width:240px;}

  /* FRIEND qualities */
  .friend{padding:112px 0 116px;background:linear-gradient(180deg,var(--showTop),var(--friendMid) 55%,var(--showTop));}
  .friend h2{font-family:var(--serif);font-weight:400;font-size:clamp(28px,4.4vw,46px);text-align:center;color:var(--ink);letter-spacing:-.015em;margin:0 auto 14px;max-width:18ch;}
  .friend .lede{font-family:var(--serif);font-size:17px;color:var(--soft);text-align:center;max-width:46ch;margin:0 auto 58px;}
  .fgrid{display:grid;grid-template-columns:1fr 1fr;gap:20px;max-width:920px;margin:0 auto;}
  .fcard{position:relative;background:linear-gradient(160deg,rgba(255,255,255,.05),rgba(255,255,255,.02));border:1px solid var(--line);border-radius:22px;padding:36px 34px;overflow:hidden;}
  .fcard::before{content:'';position:absolute;top:-40px;right:-40px;width:160px;height:160px;border-radius:50%;background:radial-gradient(closest-side,rgba(var(--glowTriple),.10),transparent);}
  .fcard h3{position:relative;font-family:var(--serif);font-weight:400;font-size:clamp(22px,2.7vw,27px);color:var(--ink);line-height:1.2;margin-bottom:13px;letter-spacing:-.01em;}
  .fcard p{position:relative;font-size:14.5px;line-height:1.72;color:var(--soft);}

  /* HOW band (light) */
  section.band{padding:108px 0 92px;background:linear-gradient(180deg,var(--showTop),var(--screen) 150px);color:var(--pink);}
  .band h2{font-family:var(--serif);font-weight:400;font-size:clamp(26px,4vw,40px);text-align:center;letter-spacing:-.01em;margin:0 auto 48px;max-width:20ch;}
  .band .kick{color:var(--sageDk);}
  .beats{display:grid;grid-template-columns:repeat(3,1fr);gap:24px;}
  .beat{text-align:center;padding:0 14px;}
  .beat .when{font-family:var(--serif);font-style:italic;font-size:15px;color:var(--sageDk);margin-bottom:12px;}
  .beat h3{font-family:var(--serif);font-weight:400;font-size:23px;margin-bottom:10px;}
  .beat p{font-size:14.5px;line-height:1.65;color:var(--pmuted);max-width:32ch;margin:0 auto;}
  .pillars{display:grid;grid-template-columns:1fr 1fr;gap:22px;max-width:820px;margin:60px auto 0;}
  .pillar{background:var(--paperHi);border:1px solid var(--phair);border-radius:18px;padding:30px 28px;}
  .pillar h3{font-family:var(--serif);font-weight:400;font-size:21px;margin-bottom:8px;}
  .pillar p{font-size:14.5px;line-height:1.65;color:var(--pmuted);}

  /* FAQ */
  .faq-band{background:var(--paper);}
  .faqwrap{max-width:760px;margin:0 auto;}
  details.faq{background:var(--paperHi);border:1px solid var(--phair);border-radius:14px;margin-bottom:12px;transition:border-color .2s;}
  details.faq:hover{border-color:rgba(95,127,95,.35);}
  details.faq summary{list-style:none;cursor:pointer;padding:20px 24px;font-family:var(--serif);font-size:clamp(17px,2vw,20px);color:var(--pink);display:flex;justify-content:space-between;align-items:center;gap:16px;}
  details.faq summary::-webkit-details-marker{display:none;}
  details.faq summary::after{content:'+';font-family:var(--meta);font-weight:400;font-size:24px;line-height:1;color:var(--sageDk);flex:0 0 auto;}
  details.faq[open] summary::after{content:'\\2013';}
  details.faq .a{padding:0 24px 22px;font-size:15px;line-height:1.72;color:var(--pmuted);}
  .content-band{background:var(--paper);color:var(--pink);}
  .content-band .prose{max-width:740px;margin:0 auto;}
  .content-band .prose h3{font-family:var(--serif);font-weight:400;font-size:clamp(20px,2.4vw,26px);margin:34px 0 10px;color:var(--pink);}
  .content-band .prose p,.content-band .prose li{font-size:16px;line-height:1.75;color:var(--pmuted);}
  .content-band .prose ul{margin:8px 0 8px 22px;}
  .content-band .prose li{margin-bottom:8px;}

  /* CLOSING */
  .closing{text-align:center;padding:128px 0;background:radial-gradient(120% 90% at 50% 120%,var(--forest),var(--showTop) 65%);color:var(--ink);position:relative;overflow:hidden;}
  .closing .lock{font-size:58px;margin-bottom:24px;color:var(--ink);}.closing .lock .mk svg g{stroke:var(--sage);}
  .closing h2{font-family:var(--serif);font-weight:400;font-size:clamp(28px,4.6vw,44px);margin-bottom:18px;letter-spacing:-.01em;max-width:20ch;margin-left:auto;margin-right:auto;}
  .closing p{font-family:var(--serif);font-size:17px;color:var(--soft);max-width:40ch;margin:0 auto 30px;line-height:1.55;}
  .closing .btn{background:var(--sage);color:var(--ctaInk);}

  .ori-signup{background:var(--night);padding:64px 0;border-top:1px solid var(--line);}
  .ori-signup .sgwrap{max-width:560px;margin:0 auto;padding:0 24px;text-align:center;}
  .ori-signup h2{font-family:var(--serif);font-size:30px;color:var(--ink);margin:0 0 10px;letter-spacing:-.01em;}
  .ori-signup p{font-family:var(--meta);color:var(--soft);font-size:16px;margin:0 0 22px;}
  .ori-signup form{display:flex;gap:10px;max-width:440px;margin:0 auto;flex-wrap:wrap;}
  .ori-signup input{flex:1;min-width:200px;font-family:var(--meta);font-size:15px;padding:13px 16px;border-radius:12px;border:1px solid rgba(168,197,139,.28);background:var(--panel);color:var(--ink);}
  .ori-signup input::placeholder{color:var(--faint);}
  .ori-signup button{font-family:var(--meta);font-weight:600;font-size:15px;padding:13px 24px;border-radius:12px;border:0;background:var(--sage);color:var(--ctaInk);cursor:pointer;}
  .ori-signup button:hover{filter:brightness(1.08);}
  .ori-signup .msg{margin-top:14px;font-family:var(--meta);font-size:14px;color:var(--sage);min-height:20px;}
  footer{background:var(--night);color:var(--soft);padding:34px 0;border-top:1px solid rgba(255,255,255,.06);}
  .foot-in{display:flex;flex-wrap:wrap;gap:18px;align-items:center;justify-content:space-between;}
  .foot-in .lock{font-size:22px;color:var(--ink);}.foot-in .lock .mk svg g{stroke:var(--sage);}
  .foot-links{display:flex;gap:20px;flex-wrap:wrap;}
  .foot-explore{display:flex;gap:16px;flex-wrap:wrap;flex-basis:100%;order:3;padding-top:14px;margin-top:6px;border-top:1px solid rgba(255,255,255,.06);}
  .foot-explore a{font-family:var(--meta);font-size:12.5px;color:var(--faint);text-decoration:none;}
  .foot-explore a:hover{color:var(--sage);}
  .foot-links a,.foot-crisis{font-family:var(--meta);font-size:13px;color:var(--soft);}
  .foot-crisis{font-family:var(--serif);font-style:italic;}.foot-crisis a{color:var(--amber);}

  @media (max-width:880px){.hero-grid{grid-template-columns:1fr;gap:50px;text-align:center;}.hero-copy p.sub{margin-left:auto;margin-right:auto;}.cta-row{justify-content:center;}.hk{text-align:center;}}
  @media (max-width:760px){
    .fgrid,.beats,.pillars{grid-template-columns:1fr;}
    .stage{height:auto;flex-direction:column;gap:22px;}
    .shot{position:static;transform:none!important;box-shadow:0 24px 60px rgba(0,0,0,.5);}
    .shot img,.shot.center img{width:230px;}
  }
  @media (prefers-reduced-motion:reduce){.hero::before{animation:none;}}
`;
