window.JL_CONFIG = Object.freeze({
  supabaseUrl: 'https://bxndjyzghgrmkelshtdp.supabase.co',
  supabaseKey: 'sb_publishable_E-Uikud2p7M6-dgcCK5ttg_eWUV8i_l'
});

(() => {
  if (!document.querySelector('a[href*="ludo"]') && !location.pathname.includes('ludo')) return;

  const experience = document.createElement('script');
  experience.src = './ludo-experience.js';
  experience.defer = true;
  document.head.appendChild(experience);

  if (location.pathname.includes('ludo')) {
    const challenges = document.createElement('script');
    challenges.src = './ludo-public-challenges.js';
    challenges.defer = true;
    document.head.appendChild(challenges);
  }
})();
