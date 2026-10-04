(() => {
  'use strict';

  const $ = (selector, root = document) => root.querySelector(selector);
  const token = () => window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
  const rpc = (name, args = {}) => window.JLApi?.rpc?.(name, args);
  const money = (value) => Number(value || 0).toLocaleString('pt-MZ', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

  function pathName() {
    return String(location.pathname || '/').toLowerCase();
  }

  function isIndexPage() {
    const path = pathName();
    return path === '/' || path.endsWith('/index.html');
  }

  function isLudoPage() {
    return pathName().endsWith('/ludo.html');
  }

  function pageKind() {
    const path = pathName();
    if (path.endsWith('/ludo.html') || path.endsWith('/dama.html') || path.endsWith('/tabuleiro.html')) return 'tabuleiro';
    if (path.endsWith('/aviator.html')) return 'aviator';
    const hash = location.hash.toLowerCase();
    if (hash.includes('sorteios') || hash.includes('numero-lendario') || hash.includes('dupla-lendaria')) return 'sorteios';
    if (hash.includes('playerarea') || hash.includes('account')) return 'conta';
    return 'todos';
  }

  function headerMarkup() {
    const refreshId = isLudoPage() ? 'refreshLobby' : 'jlHeaderRefresh';
    return `
      <a class="brand" href="./index.html" aria-label="Jogos Lendários">Jogos <strong>Lendários</strong></a>
      <nav class="game-nav" aria-label="Categorias de jogos">
        <a data-jl-nav="todos" href="./index.html#catalogo">Todos</a>
        <a data-jl-nav="sorteios" href="./index.html#sorteios">Sorteios</a>
        <a data-jl-nav="aviator" class="nav-aviator-symbol" href="./aviator.html" aria-label="Aviator" title="Aviator"><span aria-hidden="true">✈</span></a>
        <a data-jl-nav="tabuleiro" href="./tabuleiro.html">Tabuleiro</a>
        <a data-jl-nav="conta" href="#account">Conta</a>
      </nav>
      <div class="top-actions">
        <button id="${refreshId}" class="top-refresh-button" type="button" aria-label="Atualizar página">⟳</button>
        <span id="numberRoundBadge" class="badge muted jl-header-legacy-hidden">Número</span>
        <span id="pairRoundBadge" class="badge muted jl-header-legacy-hidden">Dupla</span>
        <span id="identityBadge" class="badge jl-header-legacy-hidden">Não autenticado</span>
        <strong id="damaBalance" class="jl-header-legacy-hidden">—</strong>
        <div id="aviatorBalance" class="aviator-top-balance jl-header-legacy-hidden" hidden><span>Saldo</span><strong>—</strong></div>
        <div class="account-popover-wrap">
          <button id="accountButton" class="button ghost small" type="button" aria-expanded="false" aria-controls="accountMenu">Entrar</button>
          <div id="accountMenu" class="account-menu hidden" role="dialog" aria-label="Resumo da conta">
            <div class="account-menu-head">
              <div>
                <small>Jogador</small>
                <strong id="accountMenuPlayer">—</strong>
                <strong id="accountMenuCode" class="jl-header-code-alias">—</strong>
              </div>
              <div class="account-balance">
                <small>Saldo</small>
                <strong id="accountMenuBalance">0,00 MZN</strong>
                <small id="accountMenuBonus">Bónus 0,00 MZN</small>
              </div>
            </div>
            <div class="account-menu-actions">
              <button id="accountMenuDeposit" class="button success small" type="button">Depósito</button>
              <button id="accountMenuWithdraw" class="button secondary small" type="button">Saque</button>
              <button id="accountMenuSupport" class="button support-button small" data-open-support type="button">Mensagem</button>
              <button id="accountMenuSessions" class="button ghost small" type="button">Sessões</button>
              <button id="accountMenuLogout" class="button danger logout-red small" type="button">Sair</button>
            </div>
          </div>
        </div>
      </div>`;
  }

  function buildSharedHeader() {
    const bar = $('.topbar');
    if (!bar) return null;
    bar.innerHTML = headerMarkup();
    bar.dataset.jlSharedHeader = '1';
    const active = bar.querySelector(`[data-jl-nav="${pageKind()}"]`);
    active?.classList.add('active');
    return bar;
  }

  function normalizeNav() {
    const nav = $('.game-nav');
    if (!nav) return;
    nav.querySelectorAll('[data-jl-nav]').forEach((link) => {
      link.classList.toggle('active', link.dataset.jlNav === pageKind());
    });
  }

  function ensureStyle(href, marker) {
    if (document.querySelector(`link[data-${marker}]`)) return;
    const path = href.split('?')[0].replace(/^\.\//, '/');
    const exists = [...document.styleSheets].some((sheet) => {
      try { return new URL(sheet.href || '', location.href).pathname.endsWith(path); } catch { return false; }
    });
    if (exists) return;
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = href;
    link.dataset[marker.replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = '1';
    document.head.appendChild(link);
  }

  function ensureSharedStyles() {
    ensureStyle('./site-header-enforce.css?v=20261004-1', 'jl-header-enforce');
    ensureStyle('./site-account.css?v=20261004-1', 'jl-site-account');
    ensureStyle('./support-ui.css?v=20260922-12fix', 'jl-support-style');
  }

  function ensureToast() {
    if ($('#toast')) return;
    const toast = document.createElement('div');
    toast.id = 'toast';
    toast.className = 'jl-header-global-toast';
    toast.setAttribute('role', 'status');
    toast.setAttribute('aria-live', 'polite');
    document.body.appendChild(toast);
  }

  function showToast(text, type = '') {
    const toast = $('#toast');
    if (!toast) return;
    toast.textContent = String(text || '');
    if (toast.classList.contains('toast')) {
      toast.className = `toast show ${type}`.trim();
      clearTimeout(showToast.timer);
      showToast.timer = setTimeout(() => { toast.className = 'toast'; }, 3200);
      return;
    }
    toast.className = `jl-header-global-toast show ${type}`.trim();
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => { toast.className = 'jl-header-global-toast'; }, 3200);
  }

  function closeAccountMenu() {
    $('#accountMenu')?.classList.add('hidden');
    $('#accountButton')?.setAttribute('aria-expanded', 'false');
  }

  function openAccountMenu() {
    const menu = $('#accountMenu');
    const button = $('#accountButton');
    if (!menu || !button) return;
    menu.classList.remove('hidden');
    button.setAttribute('aria-expanded', 'true');
  }

  function toggleAccountMenu() {
    const menu = $('#accountMenu');
    if (!menu) return;
    if (menu.classList.contains('hidden')) openAccountMenu();
    else closeAccountMenu();
  }

  function setAccountFields(data) {
    const player = data?.player || data?.identity || {};
    const bonus = data?.bonus || {};
    const name = String(player.name || player.code || 'Conta').trim() || 'Conta';
    const code = String(player.code || name);
    const balance = Number(player.balance);
    const bonusTotal = Number(bonus.total ?? player.bonus_balance ?? 0) || 0;

    const button = $('#accountButton');
    if (button) {
      button.textContent = name;
      button.title = Number.isFinite(balance) ? `Saldo: ${money(balance)} MZN` : 'Conta';
    }
    if ($('#accountMenuPlayer')) $('#accountMenuPlayer').textContent = name;
    if ($('#accountMenuCode')) $('#accountMenuCode').textContent = code;
    if ($('#accountMenuBalance')) $('#accountMenuBalance').textContent = Number.isFinite(balance) ? `${money(balance)} MZN` : '—';
    if ($('#accountMenuBonus') && (data?.bonus || player.bonus_balance != null)) $('#accountMenuBonus').textContent = `Bónus ${money(bonusTotal)} MZN`;
    if ($('#identityBadge')) $('#identityBadge').textContent = code;
  }

  function setLoggedOutHeader() {
    const button = $('#accountButton');
    if (button) {
      button.textContent = 'Entrar';
      button.title = 'Entrar na conta';
    }
    if ($('#accountMenuPlayer')) $('#accountMenuPlayer').textContent = '—';
    if ($('#accountMenuCode')) $('#accountMenuCode').textContent = '—';
    if ($('#accountMenuBalance')) $('#accountMenuBalance').textContent = '0,00 MZN';
    if ($('#accountMenuBonus')) $('#accountMenuBonus').textContent = 'Bónus 0,00 MZN';
    closeAccountMenu();
  }

  async function refreshAccount() {
    const current = token();
    if (!current || !rpc) {
      setLoggedOutHeader();
      return null;
    }
    try {
      const data = await rpc('jl_player_state', { p_token: current });
      if (!data?.player) {
        setLoggedOutHeader();
        return null;
      }
      setAccountFields(data);
      return data;
    } catch (error) {
      if (/sess[aã]o|session/i.test(String(error?.message || ''))) setLoggedOutHeader();
      return null;
    }
  }

  function retryFind(selectors, callback, attempt = 0) {
    for (const selector of selectors) {
      const node = $(selector);
      if (node) {
        callback(node);
        return;
      }
    }
    if (attempt >= 20) return;
    setTimeout(() => retryFind(selectors, callback, attempt + 1), 100);
  }

  function scrollFinancial(kind = 'account') {
    closeAccountMenu();
    const selectors = kind === 'deposit'
      ? ['#depositPanel', '#jlAccountDepositForm', '#jlGlobalAccountFooter', '#playerArea']
      : kind === 'withdraw'
        ? ['#withdrawPanel', '#jlAccountWithdrawForm', '#jlGlobalAccountFooter', '#playerArea']
        : ['#playerArea', '#jlGlobalAccountFooter'];
    retryFind(selectors, (node) => {
      const target = node.closest?.('#jlGlobalAccountFooter, #playerArea, .jl-account-panel') || node;
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      if (kind === 'deposit') $('#jlAccountDepositAmount, #depositAmount')?.focus?.({ preventScroll: true });
      if (kind === 'withdraw') $('#jlAccountWithdrawAmount, #withdrawAmount')?.focus?.({ preventScroll: true });
    });
  }

  function loadScriptOnce(src, marker) {
    const bare = src.split('?')[0].replace(/^\.\//, '/');
    const existing = [...document.scripts].find((script) => {
      try { return new URL(script.src, location.href).pathname.endsWith(bare); } catch { return false; }
    });
    if (existing) {
      if (existing.dataset.jlLoaded === '1' || !existing.async) return Promise.resolve(existing);
      return new Promise((resolve) => {
        existing.addEventListener('load', () => resolve(existing), { once: true });
        setTimeout(() => resolve(existing), 1200);
      });
    }
    return new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = src;
      script.async = true;
      if (marker) script.dataset[marker] = '1';
      script.addEventListener('load', () => {
        script.dataset.jlLoaded = '1';
        resolve(script);
      }, { once: true });
      script.addEventListener('error', reject, { once: true });
      document.head.appendChild(script);
    });
  }

  async function ensureLogoutConfirm() {
    if (typeof window.JLConfirmLogout === 'function') return true;
    try { await loadScriptOnce('./logout-confirm.js?v=20260924-2', 'jlLogoutConfirmLoader'); } catch {}
    return typeof window.JLConfirmLogout === 'function';
  }

  function openLogin() {
    closeAccountMenu();
    const modal = $('#authModal');
    if (modal) {
      modal.classList.remove('hidden');
      document.body.classList.add('modal-open');
      setTimeout(() => {
        $('#loginTab')?.click();
        $('#loginPhone')?.focus?.();
      }, 0);
      return;
    }
    location.href = './index.html#login';
  }

  async function genericLogout() {
    const current = token();
    if (!current) return;
    await ensureLogoutConfirm();
    if (typeof window.JLConfirmLogout === 'function' && !(await window.JLConfirmLogout())) return;
    if (typeof window.JLConfirmLogout !== 'function' && !window.confirm('Sair da conta?')) return;

    try { await rpc?.('jl_logout_player', { p_token: current }); } catch {}
    if (window.JLSession?.setPlayerToken) window.JLSession.setPlayerToken('');
    else {
      localStorage.removeItem('jl_player_token');
      window.dispatchEvent(new CustomEvent('jl-player-session-changed', { detail: { authenticated: false } }));
    }
    setLoggedOutHeader();
    window.JLAccountFooter?.refresh?.();
    showToast('Sessão encerrada.', 'success');
  }

  function bindSharedHeaderActions() {
    const refresh = isLudoPage() ? $('#refreshLobby') : $('#jlHeaderRefresh');
    refresh?.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopImmediatePropagation();
      location.reload();
    }, true);

    $('#accountButton')?.addEventListener('click', async (event) => {
      event.preventDefault();
      event.stopImmediatePropagation();
      if (!token()) {
        openLogin();
        return;
      }
      toggleAccountMenu();
      if (!$('#accountMenu')?.classList.contains('hidden')) await refreshAccount();
    }, true);

    $('#accountMenuDeposit')?.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopImmediatePropagation();
      scrollFinancial('deposit');
    }, true);

    $('#accountMenuWithdraw')?.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopImmediatePropagation();
      scrollFinancial('withdraw');
    }, true);

    document.addEventListener('click', (event) => {
      const logout = event.target.closest?.('#accountMenuLogout,#logoutButton,#jlAccountLogout');
      if (!logout) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      genericLogout();
    }, true);

    document.addEventListener('click', (event) => {
      const menu = $('#accountMenu');
      if (!menu || menu.classList.contains('hidden')) return;
      if (event.target.closest('#accountButton') || event.target.closest('#accountMenu')) return;
      closeAccountMenu();
    });

    document.addEventListener('click', (event) => {
      const link = event.target.closest?.('.game-nav [data-jl-nav="conta"]');
      if (!link) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      if (!token()) openLogin();
      else scrollFinancial('account');
    }, true);
  }

  function loadAccountPlugins() {
    ensureLogoutConfirm();
    loadScriptOnce('./js/auth/player-sessions.js?v=20260928-1', 'jlPlayerSessions').catch(() => {});
    loadScriptOnce('./support-ui.js?v=20260928-1', 'jlSupportUi').catch(() => {});
  }

  function makeMetric(label, icon, id, target) {
    const button = document.createElement('button');
    button.className = 'status-metric';
    button.type = 'button';
    button.setAttribute('aria-label', label);
    button.innerHTML = `<span class="status-icon" aria-hidden="true">${icon}</span><strong id="${id}">0</strong>`;
    button.addEventListener('click', () => { location.href = target; });
    return button;
  }

  function hourKey(now = new Date()) {
    return [now.getFullYear(), String(now.getMonth() + 1).padStart(2, '0'), String(now.getDate()).padStart(2, '0'), String(now.getHours()).padStart(2, '0')].join('-');
  }

  function hourlyEstimatedBase(now = new Date()) {
    const input = `jogos-lendarios-online-estimado:${hourKey(now)}`;
    let hash = 2166136261;
    for (let i = 0; i < input.length; i += 1) {
      hash ^= input.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
    }
    return 50 + ((hash >>> 0) % 51);
  }

  function estimatedOnline(realOnline = 0, now = new Date()) {
    return hourlyEstimatedBase(now) + Math.max(0, Number(realOnline) || 0);
  }

  function applyEstimatedOnline(el, realOnline = 0) {
    if (!el) return;
    const real = Math.max(0, Number(realOnline) || 0);
    const value = estimatedOnline(real);
    const text = `≈${value}`;
    el.dataset.jlRealOnline = String(real);
    el.dataset.jlEstimateApplied = text;
    if (el.textContent !== text) el.textContent = text;
    const metric = el.closest('.status-metric');
    if (metric) {
      metric.setAttribute('aria-label', `Jogadores online estimados: ${value}`);
      metric.title = 'Online estimado';
    }
  }

  function updateEstimatedOnline(realOnline = 0) {
    applyEstimatedOnline($('#jlGlobalOnlineCount'), realOnline);
    applyEstimatedOnline($('#onlinePlayerCount'), realOnline);
  }

  function installLudoOnlineEstimateGuard() {
    const el = $('#onlinePlayerCount');
    if (!el || el.dataset.jlEstimateGuard === '1') return;
    el.dataset.jlEstimateGuard = '1';
    const observer = new MutationObserver(() => {
      const current = String(el.textContent || '');
      if (current === el.dataset.jlEstimateApplied) return;
      const real = Math.max(0, Number(current.replace(/[^0-9.-]/g, '')) || 0);
      applyEstimatedOnline(el, real);
    });
    observer.observe(el, { childList: true, characterData: true, subtree: true });
    const initial = Math.max(0, Number(String(el.textContent || '').replace(/[^0-9.-]/g, '')) || 0);
    applyEstimatedOnline(el, initial);
  }

  function ensureStatusStrip() {
    if ($('#ludoStatusStrip') || $('#jlGlobalStatusStrip')) return;
    const main = $('main');
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
    const current = token();
    const strip = $('#jlGlobalStatusStrip');
    updateEstimatedOnline(0);
    if (!current || !rpc) {
      strip?.classList.remove('hidden');
      if ($('#jlGlobalDirectCount')) $('#jlGlobalDirectCount').textContent = '0';
      if ($('#jlGlobalPublicCount')) $('#jlGlobalPublicCount').textContent = '0';
      return;
    }

    try {
      const status = await rpc('jl_ludo_my_status', { p_token: current });
      let publicChallenges = status?.public_challenges || [];
      try { publicChallenges = await rpc('jl_ludo_public_challenges', { p_token: current }); } catch {}
      const invites = Array.isArray(status?.invites) ? status.invites : [];
      const online = Math.max(0, Number(status?.online_count) || 0);
      const publicCount = Array.isArray(publicChallenges) ? publicChallenges.length : 0;
      updateEstimatedOnline(online);
      if ($('#jlGlobalDirectCount')) $('#jlGlobalDirectCount').textContent = String(invites.length);
      if ($('#jlGlobalPublicCount')) $('#jlGlobalPublicCount').textContent = String(publicCount);
      strip?.classList.remove('hidden');
      if (status?.identity) setAccountFields({ identity: status.identity, player: status.identity });
    } catch {
      updateEstimatedOnline(0);
      strip?.classList.remove('hidden');
    }
  }

  function loadPageEnhancements() {
    if (!pathName().endsWith('/dama.html')) return;
    loadScriptOnce('./dama-room-preview.js?v=20261004-2', 'jlDamaRoomPreview').catch(() => {});
  }

  function loadAccountFooter() {
    ensureStyle('./account-footer.css?v=20261004-1', 'jl-account-footer');

    const loadFooterScript = () => loadScriptOnce('./account-footer.js?v=20261004-2', 'jlAccountFooter').catch(() => {});
    if (window.JLFinancial) {
      loadFooterScript();
      return;
    }
    const existingFinancial = [...document.scripts].find((script) => /\/js\/bets\/financial\.js(?:\?|$)/.test(script.src));
    if (existingFinancial) {
      if (window.JLFinancial) loadFooterScript();
      else existingFinancial.addEventListener('load', loadFooterScript, { once: true });
      return;
    }
    const financial = document.createElement('script');
    financial.src = './js/bets/financial.js?v=20260928-1';
    financial.async = true;
    financial.addEventListener('load', loadFooterScript, { once: true });
    document.head.appendChild(financial);
  }

  function boot() {
    ensureSharedStyles();
    ensureToast();
    buildSharedHeader();
    bindSharedHeaderActions();
    ensureStatusStrip();
    installLudoOnlineEstimateGuard();
    loadAccountPlugins();
    loadPageEnhancements();
    loadAccountFooter();
    refreshAccount();
    refreshGlobal();

    if (isIndexPage() && location.hash.toLowerCase() === '#login') setTimeout(openLogin, 120);

    window.addEventListener('hashchange', normalizeNav);
    window.addEventListener('jl-player-session-changed', () => {
      refreshAccount();
      refreshGlobal();
      window.JLAccountFooter?.refresh?.();
    });
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') {
        refreshAccount();
        refreshGlobal();
      }
    });
    setInterval(() => {
      if (document.visibilityState === 'visible') refreshGlobal();
    }, 12000);
  }

  window.JLHeaderOnlineEstimate = Object.freeze({ base: hourlyEstimatedBase, display: estimatedOnline });
  window.JLSharedHeader = Object.freeze({
    refreshAccount,
    refreshGlobal,
    openAccountMenu,
    closeAccountMenu,
    scrollAccount: () => scrollFinancial('account'),
    logout: genericLogout,
    login: openLogin
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();