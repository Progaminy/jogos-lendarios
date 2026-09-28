(() => {
  'use strict';

  const loaded = new Map();
  const page = location.pathname.endsWith('/ludo.html') ? 'ludo' : 'home';

  const assets = {
    support: {
      style: './support-ui.css?v=20260928-27',
      script: './support-ui.js?v=20260928-27'
    },
    recovery: {
      style: './recovery-ui.css?v=20260928-27',
      script: './recovery-ui.js?v=20260928-27'
    },
    sessions: {
      script: './js/auth/player-sessions.js?v=20260928-27'
    },
    notifications: {
      script: './js/notifications/client.js?v=20260928-27'
    },
    promo: {
      script: './promo-rotator.js?v=20260928-27'
    },
    numberOrbs: {
      script: './number-orb.js?v=20260928-27'
    },
    playerUi: {
      script: './js/player/ui.js?v=20260928-27'
    },
    social: {
      script: './social.js?v=20260928-27'
    }
  };

  function token() {
    return window.JLSession?.getPlayerToken?.()
      || localStorage.getItem('jl_player_token')
      || '';
  }

  function loadStyle(href, name) {
    const key = 'style:' + name;
    if (loaded.has(key)) return loaded.get(key);

    const clean = href.split('?')[0].replace('./', '/');
    const existing = [...document.querySelectorAll('link[rel="stylesheet"]')]
      .find((el) => el.href && el.href.includes(clean));
    if (existing) {
      const done = Promise.resolve(existing);
      loaded.set(key, done);
      return done;
    }

    const promise = new Promise((resolve, reject) => {
      const link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = href;
      link.dataset.jlLazy = name;
      link.onload = () => resolve(link);
      link.onerror = () => reject(new Error('Falha ao carregar estilo: ' + name));
      document.head.appendChild(link);
    });

    loaded.set(key, promise);
    return promise;
  }

  function loadScript(src, name) {
    const key = 'script:' + name;
    if (loaded.has(key)) return loaded.get(key);

    const clean = src.split('?')[0].replace('./', '/');
    const existing = [...document.scripts]
      .find((el) => el.src && el.src.includes(clean));
    if (existing) {
      const done = Promise.resolve(existing);
      loaded.set(key, done);
      return done;
    }

    const promise = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = src;
      script.defer = true;
      script.dataset.jlLazy = name;
      script.onload = () => resolve(script);
      script.onerror = () => reject(new Error('Falha ao carregar módulo: ' + name));
      document.head.appendChild(script);
    });

    loaded.set(key, promise);
    return promise;
  }

  async function load(name) {
    const asset = assets[name];
    if (!asset) return null;

    const key = 'module:' + name;
    if (loaded.has(key)) return loaded.get(key);

    const promise = (async () => {
      if (asset.style) await loadStyle(asset.style, name);
      if (asset.script) await loadScript(asset.script, name);
      return true;
    })().catch((error) => {
      loaded.delete(key);
      console.warn('[Jogos Lendários] lazy module', name, error?.message || error);
      throw error;
    });

    loaded.set(key, promise);
    return promise;
  }

  function schedule(name, timeout = 1200) {
    const run = () => load(name).catch(() => {});
    if ('requestIdleCallback' in window) {
      requestIdleCallback(run, { timeout });
    } else {
      setTimeout(run, Math.min(timeout, 700));
    }
  }

  function observe(selector, moduleName, rootMargin = '600px') {
    const target = document.querySelector(selector);
    if (!target) return;

    if (!('IntersectionObserver' in window)) {
      schedule(moduleName, 900);
      return;
    }

    const observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return;
      observer.disconnect();
      load(moduleName).catch(() => {});
    }, { rootMargin });

    observer.observe(target);
  }

  function bootAuthenticatedModules() {
    if (!token()) return;
    schedule('notifications', 900);
    if (page === 'ludo') schedule('social', 1400);
  }

  function initViewportModules() {
    if (page !== 'home') return;
    observe('#heroPromo', 'promo', '350px');
    observe('#sorteios', 'numberOrbs', '500px');
    observe('#playerArea', 'playerUi', '800px');
  }

  function installInteractionLoading() {
    document.addEventListener('click', async (event) => {
      const supportButton = event.target.closest('[data-open-support]');
      if (supportButton && !loaded.has('module:support')) {
        event.preventDefault();
        event.stopImmediatePropagation();
        try {
          await load('support');
          supportButton.click();
        } catch {}
        return;
      }

      const accountButton = event.target.closest('#accountButton');
      const authButton = event.target.closest('[data-open-auth]');

      if ((accountButton && !token()) || authButton) {
        load('recovery').catch(() => {});
      }

      if (accountButton && token()) {
        load('sessions').catch(() => {});
      }
    }, true);

    window.addEventListener('jl-player-session-changed', (event) => {
      if (!event.detail?.authenticated) return;
      load('notifications').catch(() => {});
      if (page === 'ludo') load('social').catch(() => {});
    });
  }

  function init() {
    installInteractionLoading();
    initViewportModules();

    if (new URLSearchParams(location.search).has('jl_notice')) {
      load('notifications').catch(() => {});
    } else {
      bootAuthenticatedModules();
    }
  }

  window.JLLazy = Object.freeze({
    load,
    isLoaded(name) {
      return loaded.has('module:' + name);
    }
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }
})();
