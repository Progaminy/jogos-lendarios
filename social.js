(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  const POLL_MS = 8000;
  const LUDO_SYNC_MS = 20000;

  const state = {
    timer: null,
    busy: false,
    searchBusy: false,
    searchQuery: '',
    following: [],
    counts: { following: 0, followers: 0, online: 0 }
  };

  const ui = {};

  function token() {
    return window.JLSession?.getPlayerToken?.() || localStorage.getItem(TOKEN_KEY) || '';
  }

  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/[&<>'"]/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
    }[c]));
  }

  const rpc = (name, args = {}) => window.JLApi.rpc(name, args);

  function injectStyle() {
    if (document.getElementById('jlSocialStyle')) return;
    const style = document.createElement('style');
    style.id = 'jlSocialStyle';
    style.textContent = [
      '.jl-social-zone{margin-top:16px}',
      '.jl-social-zone.hidden{display:none!important}',
      '.jl-social-head{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:10px}',
      '.jl-social-head h2{margin:0}.jl-social-head .eyebrow{margin-bottom:3px}',
      '.jl-social-head-actions{display:flex;align-items:center;justify-content:flex-end;gap:8px;flex-wrap:wrap}',
      '.jl-social-counts{display:flex;gap:7px;flex-wrap:wrap;justify-content:flex-end}',
      '.jl-social-pill{display:inline-flex;align-items:center;gap:6px;padding:7px 10px;border:1px solid rgba(255,255,255,.11);border-radius:999px;background:rgba(255,255,255,.045);font-size:.72rem;font-weight:850;color:#dbe7f5}',
      '.jl-social-grid{display:grid;grid-template-columns:minmax(0,.95fr) minmax(0,1.05fr);gap:12px}',
      '.jl-social-card{min-width:0;padding:14px}',
      '.jl-social-search{display:flex;gap:8px;margin-top:12px}',
      '.jl-social-search input{min-width:0;flex:1}',
      '.jl-social-list{display:grid;gap:7px;margin-top:9px;max-height:320px;overflow:auto;overscroll-behavior:contain}',
      '.jl-social-player{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:8px;padding:9px 10px;border:1px solid rgba(255,255,255,.09);border-radius:11px;background:rgba(255,255,255,.035)}',
      '.jl-social-player-main{min-width:0;display:flex;align-items:center;gap:8px}',
      '.jl-social-status{width:9px;height:9px;border-radius:50%;flex:0 0 auto;background:#66758a;box-shadow:0 0 0 4px rgba(102,117,138,.10)}',
      '.jl-social-status.online{background:#42dd8d;box-shadow:0 0 0 4px rgba(66,221,141,.12),0 0 12px rgba(66,221,141,.45)}',
      '.jl-social-copy{min-width:0}.jl-social-copy strong{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:.86rem}.jl-social-copy small{display:block;margin-top:1px;color:#91a4bd;font-size:.7rem}',
      '.jl-social-tags{display:flex;gap:4px;flex-wrap:wrap;margin-top:4px}',
      '.jl-social-tag{padding:2px 5px;border-radius:999px;background:rgba(255,255,255,.07);font-size:.56rem;font-weight:800;color:#b9c9dc}',
      '.jl-social-tag.online{color:#83efb3;background:rgba(66,221,141,.09)}',
      '.jl-social-tag.game{color:#ffd776;background:rgba(244,189,66,.09)}',
      '.jl-social-actions{display:flex;gap:5px;flex:0 0 auto;align-items:center}.jl-social-actions .button{min-height:30px;padding:5px 8px;border-radius:8px;font-size:.62rem;white-space:nowrap}',
      '.jl-social-empty{padding:14px 8px;text-align:center;color:#91a4bd;border:1px dashed rgba(255,255,255,.10);border-radius:10px;font-size:.72rem}.jl-social-refresh{min-width:34px!important;width:34px;height:32px;padding:0!important;font-size:1rem!important}',
      '.online-metric.jl-social-link{cursor:pointer}.online-metric.jl-social-link:focus{outline:2px solid rgba(244,189,66,.55);outline-offset:3px}',
      '@media(max-width:760px){.jl-social-grid{grid-template-columns:1fr;gap:8px}.jl-social-card{padding:10px}.jl-social-head{align-items:center;flex-direction:row}.jl-social-counts{justify-content:flex-start}.jl-social-list{max-height:none;overflow:visible}.jl-social-player{align-items:center}.jl-social-actions{align-self:center}.jl-social-search{margin-top:8px}.jl-social-zone:not(.is-collapsed) .jl-collapse-body{padding-bottom:4px}}',
      '@media(max-width:430px){.jl-social-player{grid-template-columns:minmax(0,1fr) auto;padding:8px}.jl-social-player-main{gap:7px}.jl-social-status{width:8px;height:8px}.jl-social-actions{width:auto;display:flex;flex-direction:column;gap:4px}.jl-social-actions .button{width:auto;min-width:64px;min-height:28px;padding:4px 6px;font-size:.58rem}.jl-social-card .section-head{align-items:center}.jl-social-card .eyebrow{font-size:.58rem}.jl-social-card h3{font-size:.88rem}.jl-social-search input{font-size:.72rem;padding:8px 9px}.jl-social-search .button{padding:7px 9px;font-size:.62rem}}'
    ].join('');
    document.head.appendChild(style);
  }

  function createUi() {
    if (ui.root && ui.root.isConnected) return true;
    const anchor = document.getElementById('notificationCenter');
    if (!anchor) return false;

    injectStyle();
    const section = document.createElement('section');
    section.id = 'socialZone';
    section.className = 'jl-social-zone hidden jl-collapsible';
    section.dataset.collapseDefault = 'closed';
    section.innerHTML =
      '<div class="jl-social-head">' +
        '<div class="jl-social-head-actions">' +
          '<div class="jl-social-counts">' +
            '<span id="socialOnlineCount" class="jl-social-pill">0 online</span>' +
            '<span id="socialFollowingCount" class="jl-social-pill">0 seguindo</span>' +
            '<span id="socialFollowersCount" class="jl-social-pill">0 seguidores</span>' +
          '</div>' +
          '<button class="button ghost tiny jl-collapse-toggle jl-symbol-toggle" type="button" aria-expanded="false" aria-label="Expandir">⌄</button>' +
        '</div>' +
      '</div>' +
      '<div class="jl-collapse-body">' +
      '<div class="jl-social-grid">' +
        '<section class="panel jl-social-card">' +
          '<p class="eyebrow">ENCONTRAR</p>' +
          '<form id="socialSearchForm" class="jl-social-search">' +
            '<input id="socialSearch" maxlength="60" placeholder="Nome ou João001" autocomplete="off">' +
            '<button class="button ghost small" type="submit">Buscar</button>' +
          '</form>' +
          '<div id="socialSearchResults" class="jl-social-list"><div class="jl-social-empty">Busque um jogador para seguir.</div></div>' +
        '</section>' +
        '<section class="panel jl-social-card">' +
          '<div class="section-head"><p class="eyebrow">SEGUINDO</p><button id="refreshSocial" class="button ghost tiny jl-social-refresh" type="button" aria-label="Atualizar">⟳</button></div>' +
          '<div id="socialFollowingList" class="jl-social-list"><div class="jl-social-empty">Você ainda não segue nenhum jogador.</div></div>' +
        '</section>' +
      '</div>' +
      '</div>';

    anchor.insertAdjacentElement('afterend', section);

    ui.root = section;
    ui.online = section.querySelector('#socialOnlineCount');
    ui.followingCount = section.querySelector('#socialFollowingCount');
    ui.followersCount = section.querySelector('#socialFollowersCount');
    ui.searchForm = section.querySelector('#socialSearchForm');
    ui.search = section.querySelector('#socialSearch');
    ui.searchResults = section.querySelector('#socialSearchResults');
    ui.followingList = section.querySelector('#socialFollowingList');
    ui.refresh = section.querySelector('#refreshSocial');

    ui.searchForm.addEventListener('submit', (event) => {
      event.preventDefault();
      state.searchQuery = ui.search.value.trim();
      searchPlayers();
    });
    ui.refresh.addEventListener('click', () => loadSocial(false));

    section.addEventListener('click', (event) => {
      const inviteButton = event.target.closest('[data-social-invite]');
      if (inviteButton) {
        invitePlayer(inviteButton.dataset.socialInvite, inviteButton);
        return;
      }
      const button = event.target.closest('[data-social-target]');
      if (!button) return;
      const target = button.dataset.socialTarget;
      const follow = button.dataset.socialFollow === '1';
      changeFollow(target, follow, button);
    });

    const metric = document.querySelector('.online-metric');
    if (metric) {
      metric.classList.add('jl-social-link');
      metric.setAttribute('role', 'button');
      metric.setAttribute('tabindex', '0');
      metric.setAttribute('aria-label', 'Ver jogadores que sigo e estado online');
      const open = () => {
        section.classList.remove('hidden');
        section.scrollIntoView({ behavior: 'smooth', block: 'start' });
        loadSocial(true);
      };
      metric.addEventListener('click', open);
      metric.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          open();
        }
      });
    }

    return true;
  }

  function playerHtml(player, context) {
    const online = Boolean(player.online);
    const following = context === 'following' ? true : Boolean(player.following);
    const mutual = Boolean(player.mutual || player.follows_you);
    const tags = [
      '<span class="jl-social-tag ' + (online ? 'online' : '') + '">' + (online ? 'Online' : 'Offline') + '</span>',
      player.in_game ? '<span class="jl-social-tag game">Em jogo</span>' : '',
      mutual ? '<span class="jl-social-tag">Segue você</span>' : ''
    ].join('');

    return '<div class="jl-social-player">' +
      '<div class="jl-social-player-main">' +
        '<span class="jl-social-status ' + (online ? 'online' : '') + '" aria-hidden="true"></span>' +
        '<div class="jl-social-copy"><strong>' + escapeHtml(player.name) + '</strong><small>' + escapeHtml(player.code) + '</small><div class="jl-social-tags">' + tags + '</div></div>' +
      '</div>' +
      '<div class="jl-social-actions">' +
        ((window.JLLudoSocial && window.JLLudoSocial.canInvite && window.JLLudoSocial.canInvite()) ? '<button class="button primary small" type="button" data-social-invite="' + escapeHtml(player.player_id) + '">Convidar</button>' : '') +
        '<button class="button ' + (following ? 'ghost' : 'secondary') + ' small" type="button" data-social-target="' + escapeHtml(player.player_id) + '" data-social-follow="' + (following ? '0' : '1') + '">' + (following ? 'Deixar' : 'Seguir') + '</button>' +
      '</div>' +
    '</div>';
  }

  function renderFollowing() {
    if (!ui.root) return;
    ui.online.textContent = String(state.counts.online) + ' online';
    ui.followingCount.textContent = String(state.counts.following) + ' seguindo';
    ui.followersCount.textContent = String(state.counts.followers) + ' seguidores';

    ui.followingList.innerHTML = state.following.length
      ? state.following.map((player) => playerHtml(player, 'following')).join('')
      : '<div class="jl-social-empty">Você ainda não segue nenhum jogador. Use a busca ao lado para adicionar.</div>';
  }

  async function loadSocial(silent = true) {
    if (!createUi()) return;
    const t = token();
    ui.root.classList.toggle('hidden', !t);
    if (!t || state.busy || document.visibilityState !== 'visible') return;

    state.busy = true;
    try {
      const data = await rpc('jl_social_list', { p_token: t });
      state.following = Array.isArray(data && data.following) ? data.following : [];
      state.counts.following = Math.max(0, Number(data && data.following_count) || 0);
      state.counts.followers = Math.max(0, Number(data && data.followers_count) || 0);
      state.counts.online = Math.max(0, Number(data && data.online_count) || 0);
      renderFollowing();
    } catch (error) {
      if (!silent) {
        ui.followingList.innerHTML = '<div class="jl-social-empty">' + escapeHtml(error && error.message ? error.message : 'Não foi possível atualizar.') + '</div>';
      }
    } finally {
      state.busy = false;
    }
  }

  async function searchPlayers() {
    if (!createUi()) return;
    const t = token();
    if (!t || state.searchBusy) return;

    state.searchBusy = true;
    ui.searchResults.innerHTML = '<div class="jl-social-empty">Buscando…</div>';
    try {
      const rows = await rpc('jl_social_find_players', {
        p_token: t,
        p_query: state.searchQuery
      });
      const players = Array.isArray(rows) ? rows : [];
      ui.searchResults.innerHTML = players.length
        ? players.map((player) => playerHtml(player, 'search')).join('')
        : '<div class="jl-social-empty">Nenhum jogador encontrado.</div>';
    } catch (error) {
      ui.searchResults.innerHTML = '<div class="jl-social-empty">' + escapeHtml(error && error.message ? error.message : 'Falha na busca.') + '</div>';
    } finally {
      state.searchBusy = false;
    }
  }

  async function invitePlayer(target, button) {
    if (!target || !button || !window.JLLudoSocial || !window.JLLudoSocial.invite) return;
    button.disabled = true;
    const oldText = button.textContent;
    button.textContent = 'Enviando…';
    try {
      await window.JLLudoSocial.invite(target);
      button.textContent = 'Enviado';
      setTimeout(() => {
        if (button && button.isConnected) {
          button.disabled = false;
          button.textContent = oldText;
        }
      }, 2500);
    } catch (error) {
      button.disabled = false;
      button.textContent = oldText;
      const message = error && error.message ? error.message : 'Não foi possível enviar o convite.';
      ui.searchResults.insertAdjacentHTML('afterbegin', '<div class="jl-social-empty">' + escapeHtml(message) + '</div>');
    }
  }

  async function changeFollow(target, follow, button) {
    const t = token();
    if (!t || !target || button.disabled) return;
    button.disabled = true;
    const oldText = button.textContent;
    button.textContent = follow ? 'Seguindo…' : 'Removendo…';

    try {
      await rpc('jl_social_follow', {
        p_token: t,
        p_target_player: target,
        p_follow: follow
      });
      await loadSocial(true);
      if (state.searchQuery || ui.searchResults.querySelector('[data-social-target]')) await searchPlayers();
      window.JLNotifications && window.JLNotifications.sync && window.JLNotifications.sync();
    } catch (error) {
      button.disabled = false;
      button.textContent = oldText;
      alert(error && error.message ? error.message : 'Não foi possível alterar.');
    }
  }

  function start() {
    if (!createUi()) return;
    const refreshVisibility = () => {
      const logged = Boolean(token());
      ui.root.classList.toggle('hidden', !logged);
      if (logged && document.visibilityState === 'visible') loadSocial(true);
    };

    refreshVisibility();

    if (window.JLLudoSync?.register) {
      window.JLLudoSync.register('social', () => loadSocial(true), {
        interval: LUDO_SYNC_MS,
        when: () => Boolean(token()),
        visibleOnly: true,
        immediate: false
      });
    } else {
      state.timer = setInterval(refreshVisibility, POLL_MS);
      document.addEventListener('visibilitychange', refreshVisibility);
    }

    window.addEventListener('storage', (event) => {
      if (event.key === TOKEN_KEY) {
        refreshVisibility();
        window.JLLudoSync?.kick?.('social');
      }
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
