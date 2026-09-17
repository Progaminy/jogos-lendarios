window.JL_CONFIG = Object.freeze({
  supabaseUrl: 'https://bxndjyzghgrmkelshtdp.supabase.co',
  supabaseKey: 'sb_publishable_E-Uikud2p7M6-dgcCK5ttg_eWUV8i_l'
});

(() => {
  if (!document.querySelector('a[href*="ludo"]') && !location.pathname.includes('ludo')) return;
  const script = document.createElement('script');
  script.src = './ludo-experience.js';
  script.defer = true;
  document.head.appendChild(script);
})();
