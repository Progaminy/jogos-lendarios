window.JL_CONFIG = Object.freeze({
  supabaseUrl: 'https://bxndjyzghgrmkelshtdp.supabase.co',
  supabaseKey: 'sb_publishable_E-Uikud2p7M6-dgcCK5ttg_eWUV8i_l'
});

(() => {
  const add = (src) => {
    if (document.querySelector(`script[data-jl-src="${src}"]`)) return;
    const s = document.createElement('script');
    s.src = src;
    s.async = false;
    s.dataset.jlSrc = src;
    document.head.appendChild(s);
  };

  add('./bet-insights.js?v=1');
  add('./bet-button-guide.js?v=1');

  if (!document.querySelector('a[href*="ludo"]') && !location.pathname.includes('ludo')) return;
  add('./ludo-experience.js?v=5');
  add('./ludo-challenge-badge.js?v=3');
  if (location.pathname.includes('ludo')) {
    add('./ludo-public-challenges-v3.js?v=1');
    add('./ludo-room-flow-v2.js?v=2');
    add('./ludo-authoritative-sync.js?v=1');
    add('./ludo-rules-options-v2.js?v=1');
  }
})();
