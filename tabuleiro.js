(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const rpc = (name, args = {}) => window.JLApi.rpc(name, args);
  const token = () => window.JLSession?.getPlayerToken?.() || '';

  const els = {
    root: $('boardSocial'),
    onlineCount: $('boardOnlineCount'),
    inviteCount: $('boardInviteCount'),
    online: $('boardOnlinePane'),
    following: $('boardFollowingPane'),
    invites: $('boardInvitesPane')
  };

  const state = { online: [], following: [], invites: [], busy: false };

  function esc(v) {
    return String(v ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
  }
  function first(v) {
    return String(v || 'Jogador').trim().split(/\s+/)[0] || 'Jogador';
  }
  function empty(text) {
    return '<div class="board-social-empty">' + esc(text) + '</div>';
  }

  function playerRow(p, options = {}) {
    const id = esc(p.player_id);
    const following = Boolean(options.following);
    return '<div class="board-social-row">' +
      '<div class="board-social-person">' +
        '<strong>' + esc(first(p.name)) + '</strong>' +
        '<small>' + esc(p.code || '') + (p.online ? ' · online' : '') + '</small>' +
      '</div>' +
      '<div class="board-social-actions">' +
        '<button class="button secondary" type="button" data-board-invite="' + id + '">Convidar</button>' +
        (following ? '<button class="button ghost" type="button" data-board-unfollow="' + id + '">Deixar</button>' : '') +
      '</div>' +
    '</div>';
  }

  function inviteRow(i) {
    const incoming = i.role === 'target';
    if (i.status === 'pending') {
      return '<div class="board-social-row">' +
        '<div class="board-social-person">' +
          '<strong>' + esc(first(i.other_name)) + '</strong>' +
          '<small>' + (incoming ? 'Convidou você' : 'Convite enviado') + '</small>' +
        '</div>' +
        '<div class="board-social-actions">' +
          (incoming
            ? '<button class="button danger" type="button" data-invite-decline="' + esc(i.id) + '">Recusar</button>' +
              '<button class="button success" type="button" data-invite-accept="' + esc(i.id) + '">Aceitar</button>'
            : '<span class="badge">Aguardando</span>') +
        '</div>' +
      '</div>';
    }

    const both = i.selected_game;
    const otherChoice = i.other_choice ? (i.other_choice === 'ludo' ? 'Ludo' : 'Dama') : 'aguardando';
    const target = encodeURIComponent(i.other_id);
    const iid = encodeURIComponent(i.id);
    const launch = both
      ? '<a class="button primary" href="./' + both + '.html?board_invite=' + iid + '&invite_player=' + target + '">Configurar ' + (both === 'ludo' ? 'Ludo' : 'Dama') + '</a>'
      : '';

    return '<div class="board-social-row">' +
      '<div class="board-social-person">' +
        '<strong>' + esc(first(i.other_name)) + '</strong>' +
        '<small>Aceite · escolha dele: ' + esc(otherChoice) + '</small>' +
      '</div>' +
      '<div class="board-social-actions">' +
        '<div class="board-game-choice">' +
          '<button class="button ' + (i.my_choice === 'ludo' ? 'primary' : 'ghost') + '" type="button" data-choose-game="ludo" data-invite-id="' + esc(i.id) + '">Ludo</button>' +
          '<button class="button ' + (i.my_choice === 'dama' ? 'primary' : 'ghost') + '" type="button" data-choose-game="dama" data-invite-id="' + esc(i.id) + '">Dama</button>' +
        '</div>' +
        launch +
      '</div>' +
    '</div>';
  }

  function render() {
    if (!token()) {
      els.root?.classList.add('hidden');
      return;
    }
    els.root?.classList.remove('hidden');

    const others = state.online.filter((p) => !p.is_self);
    els.onlineCount.textContent = String(state.online.length);
    els.online.innerHTML = others.length
      ? others.map((p) => playerRow(p)).join('')
      : empty('Nenhum outro jogador online.');

    els.following.innerHTML = state.following.length
      ? state.following.map((p) => playerRow(p, { following: true })).join('')
      : empty('Você ainda não segue jogadores.');

    const activeInvites = state.invites.filter((i) => ['pending', 'accepted'].includes(i.status));
    els.inviteCount.textContent = String(activeInvites.filter((i) => i.status === 'pending' && i.role === 'target').length);
    els.invites.innerHTML = activeInvites.length
      ? activeInvites.map(inviteRow).join('')
      : empty('Nenhum convite.');
  }

  async function refresh(silent = true) {
    const t = token();
    if (!t) {
      render();
      return;
    }
    try {
      const [online, social, invites] = await Promise.all([
        rpc('jl_social_online_players', { p_token: t, p_limit: 100 }),
        rpc('jl_social_list', { p_token: t }),
        rpc('jl_board_invites_feed', { p_token: t })
      ]);
      state.online = online?.players || [];
      state.following = social?.following || [];
      state.invites = invites || [];
      render();
    } catch (error) {
      if (!silent) console.warn('tabuleiro social', error);
    }
  }

  async function action(fn) {
    if (state.busy) return;
    state.busy = true;
    try {
      await fn();
    } finally {
      state.busy = false;
    }
  }

  document.querySelector('.board-social-tabs')?.addEventListener('click', (event) => {
    const button = event.target.closest('[data-board-tab]');
    if (!button) return;
    document.querySelectorAll('[data-board-tab]').forEach((x) => x.classList.toggle('active', x === button));
    const tab = button.dataset.boardTab;
    els.online.classList.toggle('hidden', tab !== 'online');
    els.following.classList.toggle('hidden', tab !== 'following');
    els.invites.classList.toggle('hidden', tab !== 'invites');
  });

  els.root?.addEventListener('click', (event) => {
    const invite = event.target.closest('[data-board-invite]');
    if (invite) {
      void action(async () => {
        await rpc('jl_board_invite_send', {
          p_token: token(),
          p_target_player: invite.dataset.boardInvite
        });
        await refresh(false);
      });
      return;
    }

    const unfollow = event.target.closest('[data-board-unfollow]');
    if (unfollow) {
      if (!confirm('Tem certeza que deseja deixar de seguir este jogador?')) return;
      void action(async () => {
        await rpc('jl_social_follow', {
          p_token: token(),
          p_target_player: unfollow.dataset.boardUnfollow,
          p_follow: false
        });
        await refresh(false);
      });
      return;
    }

    const accept = event.target.closest('[data-invite-accept]');
    if (accept) {
      void action(async () => {
        await rpc('jl_board_invite_respond', {
          p_token: token(),
          p_invite: accept.dataset.inviteAccept,
          p_accept: true
        });
        await refresh(false);
      });
      return;
    }

    const decline = event.target.closest('[data-invite-decline]');
    if (decline) {
      void action(async () => {
        await rpc('jl_board_invite_respond', {
          p_token: token(),
          p_invite: decline.dataset.inviteDecline,
          p_accept: false
        });
        await refresh(false);
      });
      return;
    }

    const choice = event.target.closest('[data-choose-game]');
    if (choice) {
      void action(async () => {
        await rpc('jl_board_invite_choose_game', {
          p_token: token(),
          p_invite: choice.dataset.inviteId,
          p_game: choice.dataset.chooseGame
        });
        await refresh(false);
      });
    }
  });

  if (token()) {
    void refresh(false);
    setInterval(() => {
      if (!document.hidden) void refresh(true);
    }, 12000);
  }

  window.addEventListener('jl-player-session-changed', () => { void refresh(false); });
})();