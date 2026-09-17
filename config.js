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

  if (!document.querySelector('a[href*="ludo"]') && !location.pathname.includes('ludo')) return;
  add('./ludo-experience.js?v=4');
  add('./ludo-challenge-badge.js?v=3');
  if (location.pathname.includes('ludo')) add('./ludo-public-challenges-v3.js?v=1');
})();
