(() => {
  'use strict';

  const $ = (s, root = document) => root.querySelector(s);
  const token = () => window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
  const rpc = (name, args = {}) => window.JLApi?.rpc?.(name, args);

  function isAdminMode() {
    return document.body?.dataset?.jlHeaderMode === 'admin';
  }

  function pageKind() {
    const path = location.pathname.toLowerCase();
    if (isAdminMode()) return 'admin';
    if (path.endsWith('/ludo.html')) return 'tabuleiro';
    if (path.endsWith('/dama.html')) return 'tabuleiro';
    if (path.endsWith('/tabuleiro.html')) return 'tabuleiro';
    if (path.endsWith('/aviator.html')) return 'todos';
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

    if (!$('#refreshLobby') && !$('#refreshAdmin') && !$('#jlHeaderRefresh')) {
      const refresh = document.createElement('button');
      refresh.id = 'jlHeaderRefresh';
      refresh.className = 'top-refresh-button';
      refresh.type = 'button';
      refresh.setAttribute('aria-label', 'Atualizar');
      refresh.textContent = '⟳';
      refresh.addEventListener('click', async () => {
        refresh.disabled = true;
        try {
          await refreshGlobal();
          window.JLNotifications?.refresh?.();
        } finally {
          setTimeout(() => { refresh.disabled = false; }, 350);
        }
      });
      actions.prepend(refresh);
    }

    if (!isAdminMode() && !$('#accountButton') && !$('#jlHeaderAccount')) {
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

  function ensureStatusStrip() {
    if (isAdminMode() || $('#ludoStatusStrip') || $('#jlGlobalStatusStrip')) return;
    const main = document.querySelector('main');
    if (!main) return;

    const strip = document.createElement('section');
    strip.id = 'jlGlobalStatusStrip';
    strip.className = 'ludo-status-strip jl-global-status-strip hidden';
    strip.setAttribute('aria-label', 'Estado dos Jogos Lendários');
    strip.append(
      makeMetric('Ver jogadores online', '●', 'jlGlobalOnlineCount', './ludo.html#socialZone'),
      makeMetric('Convites individuais', '🔔', 'jlGlobalDirectCount', './ludo.html#notificationCenter'),
      makeMetric('Convites populares', '📣', 'jlGlobalPublicCount', './ludo.html#notificationCenter'),
      makeMetric('Part.', '', 'jlGlobalPartCount', './ludo.html#notificationCenter'),
      makeMetric('Pop.', '', 'jlGlobalPopCount', './ludo.html#notificationCenter')
    );
    main.prepend(strip);
  }

  async function refreshGlobal() {
    if (isAdminMode()) return;
    const t = token();
    const strip = $('#jlGlobalStatusStrip');
    const genericAccount = $('#jlHeaderAccount');

    if (!t || !rpc) {
      strip?.classList.add('hidden');
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
      set('jlGlobalOnlineCount', online);
      set('jlGlobalDirectCount', invites.length);
      set('jlGlobalPartCount', invites.length);
      set('jlGlobalPublicCount', publicCount);
      set('jlGlobalPopCount', publicCount);

      strip?.classList.remove('hidden');

      if (genericAccount) {
        const i = status?.identity;
        genericAccount.textContent = i?.name || i?.code || 'Conta';
        if (i?.balance != null) genericAccount.title = 'Saldo: ' + Number(i.balance || 0).toLocaleString('pt-MZ', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' MZN';
      }
    } catch {
      strip?.classList.add('hidden');
    }
  }

  function boot() {
    normalizeNav();
    ensureTopActions();
    ensureStatusStrip();
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