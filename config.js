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

  add('./bet-insights.js?v=2');
  add('./bet-success-ui.js?v=1');

  const isLudoPage = location.pathname.includes('ludo');
  if (!document.querySelector('a[href*="ludo"]') && !isLudoPage) return;
  if (!isLudoPage) add('./ludo-challenge-badge.js?v=5');

  if (isLudoPage) {
    // A sala e o tabuleiro têm uma única fonte de estado: ludo.js.
    // O módulo público cuida apenas da descoberta/entrada em desafios.
    // ludo-stable-ui é somente apresentação e não consulta o servidor.
    add('./ludo-public-challenges-v3.js?v=6');
    add('./ludo-stable-ui.js?v=1');
  }
})();
