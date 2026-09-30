(() => {
  'use strict';

  const FEATURES = Object.freeze({
    support: {
      css: ['./support-ui.css?v=20260922-12fix'],
      js: ['./support-ui.js?v=20260928-1']
    },
    recovery: {
      css: ['./recovery-ui.css?v=20260922-13'],
      js: ['./recovery-ui.js?v=20260928-2']
    },
    notifications: {
      js: ['./js/notifications/client.js?v=20260928-22']
    },
    sessions: {
      js: ['./js/auth/player-sessions.js?v=20260928-1']
    },
    promo: {
      js: ['./promo-rotator.js?v=20260924-1']
    },
    numberOrbs: {
      js: ['./number-orb.js?v=20260924-2']
    },
    playerExtras: {
      js: ['./js/player/ui.js?v=20260928-1']
    },
    social: {
      js: ['./social.js?v=20260929-2']
    }
  });

  const featureState = new Map();
  const notificationQueue = [];
  let notificationFacade = null;
  let supportReplay = false;
  let manifestPromise = null;

  function absolute(url) {
    return new URL(url, document.baseURI).href;
  }

  function alreadyLoaded(kind, url) {
    const target = absolute(url);
    const selector = kind === 'style' ? 'link[rel="stylesheet"][href]' : 'script[src]';
    return [...document.querySelectorAll(selector)].some((node) => absolute(node.getAttribute(kind === 'style' ? 'href' : 'src')) === target);
  }

  function loadStyle(url) {
    if (alreadyLoaded('style', url)) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = url;
      link.dataset.jlLazyAsset = '1';
      link.onload = () => resolve();
      link.onerror = () => reject(new Error('Falha ao carregar estilo opcional.'));
      document.head.appendChild(link);
    });
  }

  function loadScript(url) {
    if (alreadyLoaded('script', url)) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = url;
      script.async = true;
      script.dataset.jlLazyAsset = '1';
      script.onload = () => resolve();
      script.onerror = () => reject(new Error('Falha ao carregar módulo opcional.'));
      document.head.appendChild(script);
    });
  }

  function isLoaded(name) {
    return featureState.get(name)?.status === 'loaded';
  }

  function flushNotificationQueue() {
    const api = window.JLNotifications;
    if (!api || api === notificationFacade) return;
    while (notificationQueue.length) {
      const [method, args] = notificationQueue.shift();
      try { api[method]?.(...args); } catch {}
    }
  }

  function load(name) {
    const existing = featureState.get(name);
    if (existing?.promise) return existing.promise;

    const spec = FEATURES[name];
    if (!spec) return Promise.reject(new Error('Módulo opcional desconhecido.'));

    const state = { status: 'loading', promise: null };
    state.promise = Promise.all([
      ...(spec.css || []).map(loadStyle),
      ...(spec.js || []).map(loadScript)
    ]).then(() => {
      state.status = 'loaded';
      if (name === 'notifications') flushNotificationQueue();
      return true;
    }).catch((error) => {
      featureState.delete(name);
      throw error;
    });

    featureState.set(name, state);
    return state.promise;
  }

  function idle(name, timeout = 1600, condition = null) {
    const run = () => {
      if (condition && !condition()) return;
      load(name).catch(() => {});
    };
    if ('requestIdleCallback' in window) {
      window.requestIdleCallback(run, { timeout });
    } else {
      setTimeout(run, Math.min(timeout, 900));
    }
  }

  function visible(selector, name, rootMargin = '280px') {
    const target = document.querySelector(selector);
    if (!target) return;
    if (!('IntersectionObserver' in window)) {
      idle(name, 700);
      return;
    }

    const observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return;
      observer.disconnect();
      load(name).catch(() => {});
    }, { rootMargin });

    observer.observe(target);
  }

  function hasPlayerToken() {
    try {
      return Boolean(window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token'));
    } catch {
      return false;
    }
  }

  function networkAllowsPrefetch() {
    const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
    if (!connection) return true;
    if (connection.saveData) return false;
    return !['slow-2g', '2g'].includes(String(connection.effectiveType || '').toLowerCase());
  }

  function prefetchHref(href) {
    if (!href || !networkAllowsPrefetch()) return;
    let url;
    try { url = new URL(href, location.href); } catch { return; }
    if (url.origin !== location.origin) return;

    const canonical = url.origin + url.pathname + url.search;
    if ([...document.querySelectorAll('link[rel="prefetch"]')].some((link) => {
      try { return new URL(link.href).href === canonical; } catch { return false; }
    })) return;

    const link = document.createElement('link');
    link.rel = 'prefetch';
    link.href = canonical;
    link.dataset.jlRoutePrefetch = '1';
    document.head.appendChild(link);
  }

  async function gameManifest() {
    if (!manifestPromise) {
      manifestPromise = fetch('./games/manifest.json', {
        method: 'GET',
        cache: 'force-cache',
        credentials: 'same-origin'
      }).then((response) => {
        if (!response.ok) throw new Error('Catálogo de jogos indisponível.');
        return response.json();
      }).catch((error) => {
        manifestPromise = null;
        throw error;
      });
    }
    return manifestPromise;
  }

  async function game(id) {
    const manifest = await gameManifest();
    return (manifest.games || []).find((item) => item.id === id) || null;
  }

  async function navigateGame(id) {
    const item = await game(id);
    if (!item?.route) return false;
    location.href = item.route;
    return true;
  }

  function installNotificationFacade() {
    if (window.JLNotifications) return;

    const call = (method) => (...args) => {
      notificationQueue.push([method, args]);
      load('notifications').catch(() => {});
    };

    const setActive = (value) => {
      if (!value) {
        notificationQueue.length = 0;
        return;
      }
      notificationQueue.push(['setActive', [true]]);
      load('notifications').catch(() => {});
    };

    notificationFacade = Object.freeze({
      push: call('push'),
      markRead: call('markRead'),
      markAllRead: call('markAllRead'),
      clearAll: call('clearAll'),
      setActive,
      refresh: call('refresh'),
      sync: call('sync')
    });
    window.JLNotifications = notificationFacade;
  }

  function observeRecoveryNeed() {
    const modal = document.getElementById('authModal');
    if (!modal) return;

    const check = () => {
      if (!modal.classList.contains('hidden')) load('recovery').catch(() => {});
    };
    new MutationObserver(check).observe(modal, { attributes: true, attributeFilter: ['class'] });
    check();
  }

  function installSupportOnDemand() {
    document.addEventListener('click', async (event) => {
      const trigger = event.target.closest?.('[data-open-support]');
      if (!trigger || supportReplay || isLoaded('support')) return;

      event.preventDefault();
      event.stopImmediatePropagation();

      try {
        await load('support');
        supportReplay = true;
        trigger.click();
      } catch {
        // Keep the main page usable even if an optional module fails.
      } finally {
        supportReplay = false;
      }
    }, true);
  }

  function installAccountIntentLoading() {
    const warmAccountFeatures = (event) => {
      const target = event.target.closest?.('#accountButton');
      if (!target || !hasPlayerToken()) return;
      load('sessions').catch(() => {});
    };
    document.addEventListener('pointerover', warmAccountFeatures, { passive: true });
    document.addEventListener('focusin', warmAccountFeatures);
    document.addEventListener('click', warmAccountFeatures);
  }

  function installLazyGameNavigation() {
    document.addEventListener('click', async (event) => {
      const link = event.target.closest?.('a[data-jl-game][href]');
      if (!link) return;

      // Preserve browser-native behavior for new tab/window and downloads.
      if (
        event.defaultPrevented ||
        event.button !== 0 ||
        event.metaKey ||
        event.ctrlKey ||
        event.shiftKey ||
        event.altKey ||
        link.hasAttribute('download') ||
        link.target === '_blank'
      ) return;

      const gameId = String(link.dataset.jlGame || '').trim();
      if (!gameId) return;

      event.preventDefault();
      link.setAttribute('aria-busy', 'true');

      try {
        const item = await game(gameId);
        if (!item?.route) {
          location.href = link.href;
          return;
        }

        // Navigation is the lazy-load boundary: no game CSS/JS is injected
        // into the home page before the player explicitly opens the game.
        location.href = item.route;
      } catch {
        location.href = link.href;
      }
    });
  }

  function isLudoPage() {
    return Boolean(document.getElementById('ludoBoard') || document.getElementById('ludoLobbyBoard'));
  }

  function scheduleAuthenticatedFeatures() {
    idle('notifications', 900, hasPlayerToken);
    if (isLudoPage()) idle('social', 1400, hasPlayerToken);
  }

  function init() {
    installNotificationFacade();
    installSupportOnDemand();
    installAccountIntentLoading();
    installLazyGameNavigation();
    observeRecoveryNeed();

    // Purely visual features are loaded only when their section approaches the viewport.
    visible('#heroPromo', 'promo', '120px');
    visible('#sorteios', 'numberOrbs', '260px');

    // Account-only cleanup/UI is irrelevant to logged-out visitors.
    visible('#playerArea', 'playerExtras', '220px');

    if (hasPlayerToken()) scheduleAuthenticatedFeatures();
    window.addEventListener('jl-player-session-changed', (event) => {
      if (event.detail?.authenticated) scheduleAuthenticatedFeatures();
      else notificationQueue.length = 0;
    });
  }

  window.JLFeatureLoader = Object.freeze({
    load,
    idle,
    visible,
    isLoaded,
    gameManifest,
    game,
    navigateGame,
    prefetchHref,
    isRouteIsolated: async (id) => {
      const item = await game(id);
      return Boolean(item && item.homeEmbedded === false && item.loading === 'navigation');
    }
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }
})();
