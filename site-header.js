(() => {
  'use strict';

  const $ = (s, root = document) => root.querySelector(s);
  const token = () => window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
  const rpc = (name, args = {}) => window.JLApi?.rpc?.(name, args);

  function pageKind() {
    const path = location.pathname.toLowerCase();
    if (path.endsWith('/ludo.html')) return 'tabuleiro';
    if (path.endsWith('/dama.html')) return 'tabuleiro';
    if (path.endsWith('/tabuleiro.html')) return 'tabuleiro';
    if (path.endsWith('/aviator.html')) return 'aviator';
    const hash = location.hash.toLowerCase();
    if (hash.includes('sorteios') || hash.includes('numero-lendario') || hash.includes('dupla-lendaria')) return 'sorteios';
    if (hash.includes('playerarea')) return 'conta';
    return 'todos';
  }

  function normalizeNav() {
    const nav = $('.game-nav');
    if (!nav) return;
    nav.innerHTML = [
      '<a data-jl-nav="todos" href="./index.html#catalogo">Todos</a>',
      '<a data-jl-nav="sorteios" href="./index.html#sorteios">Sorteios</a>',
      '<a data-jl-nav="aviator" class="nav-aviator-symbol" href="./aviator.html" aria-label="Aviator" title="Aviator"><span aria-hidden="true">✈</span></a>',
      '<a data-jl-nav="tabuleiro" href="./tabuleiro.html">Tabuleiro</a>',
      '<a data-jl-nav="conta" href="./index.html#playerArea">Conta</a>'
    ].join('');
    const active = nav.querySelector('[data-jl-nav="' + pageKind() + '"]');
    active?.classList.add('active');
  }

  function ensureTopActions() {
    const bar = $('.topbar');
    if (!bar) return null;

    let actions = bar.querySelector(':scope > .top-actions');
    if (!actions) {
      actions = document.createElement('div');
      actions.className = 'top-actions';
      bar.appendChild(actions);
    }

    if (!$('#refreshLobby') && !$('#jlHeaderRefresh')) {
      const refresh = document.createElement('button');
      refresh.id = 'jlHeaderRefresh';
      refresh.className = 'top-refresh-button';
      refresh.type = 'button';
      refresh.setAttribute('aria-label', 'Atualizar');
      refresh.textContent = '⟳';
      refresh.addEventListener('click', () => {
        location.reload();
      });
      actions.prepend(refresh);
    }

    if (!$('#accountButton') && !$('#jlHeaderAccount')) {
      const account = document.createElement('a');
      account.id = 'jlHeaderAccount';
      account.className = 'button ghost small';
      account.href = './index.html#playerArea';
      account.textContent = token() ? 'Conta' : 'Entrar';
      actions.appendChild(account);
    }

    $('.dama-top-balance')?.classList.add('jl-header-legacy-hidden');
    $('.aviator-top-balance')?.classList.add('jl-header-legacy-hidden');
    return actions;
  }

  function makeMetric(label, icon, id, target) {
    const button = document.createElement('button');
    button.className = 'status-metric';
    button.type = 'button';
    button.setAttribute('aria-label', label);
    button.innerHTML = icon
      ? '<span class="status-icon" aria-hidden="true">' + icon + '</span><strong id="' + id + '">0</strong>'
      : '<span class="shortcut-label">' + label + '</span><strong id="' + id + '">0</strong>';
    button.addEventListener('click', () => { location.href = target; });
    return button;
  }

  function hourKey(now = new Date()) {
    return [
      now.getFullYear(),
      String(now.getMonth() + 1).padStart(2, '0'),
      String(now.getDate()).padStart(2, '0'),
      String(now.getHours()).padStart(2, '0')
    ].join('-');
  }

  function hourlyEstimatedBase(now = new Date()) {
    const input = 'jogos-lendarios-online-estimado:' + hourKey(now);
    let hash = 2166136261;
    for (let i = 0; i < input.length; i += 1) {
      hash ^= input.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
    }
    return 50 + ((hash >>> 0) % 51);
  }

  function estimatedOnline(realOnline = 0, now = new Date()) {
    const real = Math.max(0, Number(realOnline) || 0);
    return hourlyEstimatedBase(now) + real;
  }

  function applyEstimatedOnline(el, realOnline = 0) {
    if (!el) return;
    const real = Math.max(0, Number(realOnline) || 0);
    const value = estimatedOnline(real);
    const text = '≈' + value;
    el.dataset.jlRealOnline = String(real);
    el.dataset.jlEstimateApplied = text;
    if (el.textContent !== text) el.textContent = text;
    const metric = el.closest('.status-metric');
    if (metric) {
      metric.setAttribute('aria-label', 'Jogadores online estimados: ' + value);
      metric.title = 'Online estimado';
    }
  }

  function updateEstimatedOnline(realOnline = 0) {
    applyEstimatedOnline(document.getElementById('jlGlobalOnlineCount'), realOnline);
    applyEstimatedOnline(document.getElementById('onlinePlayerCount'), realOnline);
  }

  function installLudoOnlineEstimateGuard() {
    const el = document.getElementById('onlinePlayerCount');
    if (!el || el.dataset.jlEstimateGuard === '1') return;
    el.dataset.jlEstimateGuard = '1';

    const observer = new MutationObserver(() => {
      const current = String(el.textContent || '');
      if (current === el.dataset.jlEstimateApplied) return;
      const real = Math.max(0, Number(current.replace(/[^0-9.-]/g, '')) || 0);
      applyEstimatedOnline(el, real);
    });
    observer.observe(el, { childList: true, characterData: true, subtree: true });

    const initialReal = Math.max(0, Number(String(el.textContent || '').replace(/[^0-9.-]/g, '')) || 0);
    applyEstimatedOnline(el, initialReal);
  }

  window.JLHeaderOnlineEstimate = Object.freeze({
    base: hourlyEstimatedBase,
    display: estimatedOnline
  });

  function ensureStatusStrip() {
    if ($('#ludoStatusStrip') || $('#jlGlobalStatusStrip')) return;
    const main = document.querySelector('main');
    if (!main) return;

    const strip = document.createElement('section');
    strip.id = 'jlGlobalStatusStrip';
    strip.className = 'ludo-status-strip jl-global-status-strip';
    strip.setAttribute('aria-label', 'Estado dos Jogos Lendários');
    strip.append(
      makeMetric('Jogadores online estimados', '●', 'jlGlobalOnlineCount', './ludo.html#socialZone'),
      makeMetric('Convites individuais', '🔔', 'jlGlobalDirectCount', './ludo.html#notificationCenter'),
      makeMetric('Convites populares', '📣', 'jlGlobalPublicCount', './ludo.html#notificationCenter')
    );
    main.prepend(strip);
  }

  async function refreshGlobal() {
    const t = token();
    const strip = $('#jlGlobalStatusStrip');
    const genericAccount = $('#jlHeaderAccount');

    updateEstimatedOnline(0);

    if (!t || !rpc) {
      strip?.classList.remove('hidden');
      if (genericAccount) genericAccount.textContent = 'Entrar';
      return;
    }

    try {
      const status = await rpc('jl_ludo_my_status', { p_token: t });
      let publicChallenges = status?.public_challenges || [];
      try {
        publicChallenges = await rpc('jl_ludo_public_challenges', { p_token: t });
      } catch {}

      const invites = status?.invites || [];
      const online = Math.max(0, Number(status?.online_count) || 0);
      const publicCount = Array.isArray(publicChallenges) ? publicChallenges.length : 0;

      const set = (id, value) => {
        const el = document.getElementById(id);
        if (el) el.textContent = String(value);
      };
      updateEstimatedOnline(online);
      set('jlGlobalDirectCount', invites.length);
      set('jlGlobalPublicCount', publicCount);

      strip?.classList.remove('hidden');

      if (genericAccount) {
        const i = status?.identity;
        genericAccount.textContent = i?.name || i?.code || 'Conta';
        if (i?.balance != null) genericAccount.title = 'Saldo: ' + Number(i.balance || 0).toLocaleString('pt-MZ', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' MZN';
      }
    } catch {
      updateEstimatedOnline(0);
      strip?.classList.remove('hidden');
    }
  }

  function loadPageEnhancements() {
    const path = location.pathname.toLowerCase();
    if (!path.endsWith('/dama.html')) return;
    if (document.querySelector('script[data-jl-dama-room-preview]')) return;
    const script = document.createElement('script');
    script.src = './dama-room-preview.js?v=20261004-1';
    script.async = true;
    script.dataset.jlDamaRoomPreview = '1';
    document.head.appendChild(script);
  }

  function loadAccountFooter() {
    if (!document.querySelector('link[data-jl-account-footer]')) {
      const style = document.createElement('link');
      style.rel = 'stylesheet';
      style.href = './account-footer.css?v=20261004-1';
      style.dataset.jlAccountFooter = '1';
      document.head.appendChild(style);
    }

    const loadFooterScript = () => {
      if (window.JLAccountFooter || document.querySelector('script[data-jl-account-footer]')) return;
      const script = document.createElement('script');
      script.src = './account-footer.js?v=20261004-1';
      script.async = true;
      script.dataset.jlAccountFooter = '1';
      document.head.appendChild(script);
    };

    if (window.JLFinancial) {
      loadFooterScript();
      return;
    }

    const existingFinancial = [...document.scripts].find((s) => /\/js\/bets\/financial\.js(?:\?|$)/.test(s.src));
    if (existingFinancial) {
      if (window.JLFinancial) loadFooterScript();
      else existingFinancial.addEventListener('load', loadFooterScript, { once: true });
      return;
    }

    const financial = document.createElement('script');
    financial.src = './js/bets/financial.js?v=20260928-1';
    financial.async = true;
    financial.dataset.jlAccountFinancial = '1';
    financial.addEventListener('load', loadFooterScript, { once: true });
    document.head.appendChild(financial);
  }

  function boot() {
    normalizeNav();
    ensureTopActions();
    ensureStatusStrip();
    installLudoOnlineEstimateGuard();
    loadPageEnhancements();
    loadAccountFooter();
    refreshGlobal();
    window.addEventListener('hashchange', normalizeNav);
    window.addEventListener('jl-player-session-changed', refreshGlobal);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') refreshGlobal();
    });
    setInterval(() => {
      if (document.visibilityState === 'visible') refreshGlobal();
    }, 12000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();