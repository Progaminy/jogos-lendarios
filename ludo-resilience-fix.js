(() => {
  'use strict';
  if (window.__JL_LUDO_RESILIENCE_FIX__) return;
  window.__JL_LUDO_RESILIENCE_FIX__ = true;

  const POLL_MS = 3000;
  const cfg = window.JL_CONFIG || {};
  let lastInvites = [];
  let emptyConfirmations = 0;
  let inviteBusy = false;
  let exitBusy = false;
  let timer = 0;

  const $ = (selector, root = document) => root.querySelector(selector);

  function token() {
    try {
      return window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
    } catch {
      return '';
    }
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (ch) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
    }[ch]));
  }

  function money(value) {
    return Number(value || 0).toLocaleString('pt-MZ', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    });
  }

  async function rpc(name, args = {}) {
    if (window.JLApi?.rpc) return window.JLApi.rpc(name, args);
    if (!cfg.supabaseUrl || !cfg.supabaseKey) throw new Error('Configuração do servidor ausente.');
    const response = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      cache: 'no-store',
      headers: {
        apikey: cfg.supabaseKey,
        Authorization: `Bearer ${cfg.supabaseKey}`,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify(args)
    });
    const raw = await response.text();
    let payload = null;
    try { payload = raw ? JSON.parse(raw) : null; } catch { payload = raw; }
    if (!response.ok) throw new Error(payload?.message || payload?.hint || payload?.error || `Erro ${response.status}`);
    return payload;
  }

  function toast(message, type = '') {
    const el = $('#toast');
    if (!el) return;
    el.textContent = message;
    el.className = `toast show ${type}`.trim();
    clearTimeout(toast.t);
    toast.t = setTimeout(() => { el.className = 'toast'; }, 3600);
  }

  function injectStyles() {
    if ($('#jlLudoResilienceStyles')) return;
    const style = document.createElement('style');
    style.id = 'jlLudoResilienceStyles';
    style.textContent = `
      body.ludo-pinned{overflow:hidden!important}
      body.ludo-pinned #ludoStatusStrip{
        position:fixed!important;
        top:var(--ludo-sticky-top,56px)!important;
        left:50%!important;
        transform:translateX(-50%)!important;
        width:min(780px,calc(100vw - 12px))!important;
        z-index:39!important;
        margin:0!important;
        background:rgba(7,16,29,.97)!important;
        backdrop-filter:blur(12px)!important;
      }
      body.ludo-pinned #gamePanel>.board-panel{
        position:fixed!important;
        top:calc(var(--ludo-sticky-top,56px) + var(--jl-ludo-status-height,42px) + 4px)!important;
        left:50%!important;
        transform:translateX(-50%)!important;
        width:min(780px,calc(100vw - 12px))!important;
        height:calc(100dvh - var(--ludo-sticky-top,56px) - var(--jl-ludo-status-height,42px) - 8px)!important;
        max-height:none!important;
        overflow:auto!important;
        overscroll-behavior:contain!important;
        z-index:38!important;
        margin:0!important;
        padding:8px!important;
        border-radius:14px!important;
      }
      body.ludo-pinned #gamePanel>.board-panel #ludoBoard{
        width:min(100%,calc(100dvh - var(--ludo-sticky-top,56px) - var(--jl-ludo-status-height,42px) - 118px))!important;
        max-width:760px!important;
        margin:7px auto!important;
      }
      body.ludo-pinned #gamePanel>.board-panel .board-game-head{position:sticky;top:0;z-index:9;background:rgba(12,25,43,.96);padding:4px 2px 7px}
      body.ludo-pinned #gamePanel>.board-panel .game-controls{position:sticky;bottom:0;z-index:9;background:rgba(12,25,43,.97);padding:6px 2px}
      #room:not(.hidden) #leaveRoom.hidden{display:inline-flex!important}
      #room:not(.hidden) #leaveRoom{display:inline-flex!important}
      #room:not(.hidden) #forfeitRoom{display:none!important}
      .jl-ludo-confirm{position:fixed;inset:0;z-index:1200;display:grid;place-items:center;padding:18px;background:rgba(0,0,0,.76);backdrop-filter:blur(7px)}
      .jl-ludo-confirm.hidden{display:none!important}
      .jl-ludo-confirm-card{width:min(410px,100%);padding:23px;border-radius:20px;background:linear-gradient(160deg,#182238,#0d1422);border:1px solid rgba(244,189,66,.42);box-shadow:0 28px 90px rgba(0,0,0,.62)}
      .jl-ludo-confirm-card h2{margin:0 0 8px;font-size:1.35rem}.jl-ludo-confirm-card p{margin:0 0 18px;color:#b9c8db}
      .jl-ludo-confirm-actions{display:grid;grid-template-columns:1fr 1fr;gap:9px}
      @media(max-width:600px){
        body.ludo-pinned #ludoStatusStrip{width:100%!important;left:0!important;transform:none!important;padding-left:4px!important;padding-right:4px!important}
        body.ludo-pinned #gamePanel>.board-panel{width:100%!important;left:0!important;transform:none!important;border-radius:0!important;border-left:0!important;border-right:0!important}
      }
    `;
    document.head.appendChild(style);
  }

  function syncPinnedMetrics() {
    const strip = $('#ludoStatusStrip');
    const height = strip && !strip.classList.contains('hidden') ? Math.ceil(strip.getBoundingClientRect().height) : 0;
    document.documentElement.style.setProperty('--jl-ludo-status-height', `${Math.max(36, height)}px`);
  }

  function ensureExitButtonVisible() {
    const room = $('#room');
    const leave = $('#leaveRoom');
    if (!room || !leave || room.classList.contains('hidden')) return;
    leave.classList.remove('hidden');
    leave.textContent = 'Sair';
    $('#forfeitRoom')?.classList.add('hidden');
  }

  function updateInviteCounters(count) {
    const value = String(Math.max(0, count));
    for (const id of ['directInviteCount', 'topDirectInviteCount']) {
      const el = document.getElementById(id);
      if (el) el.textContent = value;
    }
    $('#directNotificationMetric')?.classList.toggle('has-items', count > 0);
    $('.direct-panel')?.classList.toggle('hidden', count === 0);
    $('#notificationCenter')?.classList.toggle('has-direct', count > 0);
  }

  function renderRecoveredInvites() {
    const list = $('#inviteList');
    if (!list) return;
    const invites = lastInvites;
    updateInviteCounters(invites.length);
    if (!invites.length) return;
    if (list.childElementCount > 0) return;

    list.innerHTML = invites.map((i) => `
      <div class="invite-card direct-invite" data-jl-recovered-invite="${escapeHtml(i.id)}">
        <div>
          <span class="notice-kind direct">INDIVIDUAL</span>
          <strong>${escapeHtml(i.host || 'Jogador')} · ${escapeHtml(i.host_code || '')}</strong><br>
          <small>${escapeHtml(i.room_code || '')} · ${Number(i.player_count || 0)} jogadores · ${escapeHtml(i.mode || '')}</small>
          <span class="invite-bet-value"><small>VALOR POR JOGADOR</small><strong>${money(i.bet_amount)} MZN</strong></span>
        </div>
        <div class="notice-actions">
          <button class="button success small" type="button" data-invite-accept="${escapeHtml(i.id)}" data-bet-amount="${Number(i.bet_amount || 0)}">Aceitar convite</button>
          <button class="button danger small" type="button" data-invite-decline="${escapeHtml(i.id)}">Recusar</button>
        </div>
      </div>`).join('');
  }

  async function refreshInvites() {
    if (inviteBusy || document.visibilityState !== 'visible') return;
    const t = token();
    if (!t) {
      lastInvites = [];
      emptyConfirmations = 0;
      updateInviteCounters(0);
      return;
    }
    inviteBusy = true;
    try {
      const rows = await rpc('jl_ludo_my_invites', { p_token: t });
      const invites = Array.isArray(rows) ? rows : [];
      if (invites.length) {
        emptyConfirmations = 0;
        lastInvites = invites;
      } else {
        emptyConfirmations += 1;
        if (emptyConfirmations >= 2) lastInvites = [];
      }
      renderRecoveredInvites();
    } catch {
      renderRecoveredInvites();
    } finally {
      inviteBusy = false;
    }
  }

  function ensureConfirmModal() {
    let modal = $('#jlLudoExitConfirm');
    if (modal) return modal;
    modal = document.createElement('div');
    modal.id = 'jlLudoExitConfirm';
    modal.className = 'jl-ludo-confirm hidden';
    modal.innerHTML = `
      <div class="jl-ludo-confirm-card" role="dialog" aria-modal="true" aria-labelledby="jlLudoExitTitle">
        <p class="eyebrow">LUDO LENDÁRIO</p>
        <h2 id="jlLudoExitTitle">Sair</h2>
        <p id="jlLudoExitText">Tem certeza?</p>
        <div class="jl-ludo-confirm-actions">
          <button id="jlLudoExitNo" class="button ghost" type="button">Não</button>
          <button id="jlLudoExitYes" class="button danger" type="button">Sim</button>
        </div>
      </div>`;
    document.body.appendChild(modal);
    return modal;
  }

  function askExit(message) {
    const modal = ensureConfirmModal();
    const text = $('#jlLudoExitText', modal);
    if (text) text.textContent = message;
    modal.classList.remove('hidden');
    return new Promise((resolve) => {
      const yes = $('#jlLudoExitYes', modal);
      const no = $('#jlLudoExitNo', modal);
      const done = (value) => {
        modal.classList.add('hidden');
        yes?.removeEventListener('click', onYes);
        no?.removeEventListener('click', onNo);
        resolve(value);
      };
      const onYes = () => done(true);
      const onNo = () => done(false);
      yes?.addEventListener('click', onYes, { once: true });
      no?.addEventListener('click', onNo, { once: true });
    });
  }

  async function exitCurrentRoom() {
    if (exitBusy) return;
    const t = token();
    if (!t) return;
    exitBusy = true;
    try {
      const status = await rpc('jl_ludo_my_status', { p_token: t });
      const roomId = status?.active_room_id;
      if (!roomId) {
        location.reload();
        return;
      }
      const snapshot = await rpc('jl_ludo_room_state', { p_token: t, p_room: roomId });
      const room = snapshot?.room || {};
      const started = room.status === 'playing' && Boolean(room.started_at);
      const ok = await askExit(started
        ? 'Sair agora conta como desistência desta partida. Tem certeza?'
        : 'Sair desta sala?');
      if (!ok) return;
      if (started) await rpc('jl_ludo_forfeit', { p_token: t, p_room: roomId });
      else await rpc('jl_ludo_cancel_or_leave', { p_token: t, p_room: roomId });
      toast(started ? 'Você saiu da partida.' : 'Saiu da sala.', 'success');
      setTimeout(() => location.reload(), 180);
    } catch (error) {
      toast(error?.message || 'Não foi possível sair do Ludo.', 'error');
    } finally {
      exitBusy = false;
    }
  }

  function installObservers() {
    const bodyObserver = new MutationObserver(() => {
      ensureExitButtonVisible();
      if (document.body.classList.contains('ludo-pinned')) syncPinnedMetrics();
    });
    bodyObserver.observe(document.body, { attributes: true, attributeFilter: ['class'], childList: true, subtree: true });

    const list = $('#inviteList');
    if (list) {
      new MutationObserver(() => {
        if (!list.childElementCount && lastInvites.length) renderRecoveredInvites();
      }).observe(list, { childList: true });
    }
  }

  function installEvents() {
    document.addEventListener('click', (event) => {
      const leave = event.target.closest?.('#leaveRoom');
      if (leave) {
        event.preventDefault();
        event.stopImmediatePropagation();
        exitCurrentRoom();
        return;
      }
      if (event.target.closest?.('[data-invite-accept],[data-invite-decline]')) {
        setTimeout(refreshInvites, 600);
      }
    }, true);

    window.addEventListener('resize', syncPinnedMetrics, { passive: true });
    window.addEventListener('pageshow', () => { ensureExitButtonVisible(); refreshInvites(); });
    window.addEventListener('focus', refreshInvites);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') refreshInvites();
    });
  }

  function start() {
    injectStyles();
    syncPinnedMetrics();
    ensureExitButtonVisible();
    installObservers();
    installEvents();
    refreshInvites();
    clearInterval(timer);
    timer = setInterval(refreshInvites, POLL_MS);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
