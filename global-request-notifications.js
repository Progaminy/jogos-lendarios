(() => {
  'use strict';

  if (window.__JL_REQUEST_NOTIFICATIONS_BRIDGE__) return;
  window.__JL_REQUEST_NOTIFICATIONS_BRIDGE__ = true;

  const POLL_MS = 6000;
  let busy = false;
  let timer = null;
  let countObserver = null;
  const lastCounts = { direct: 0, public: 0, ready: false };

  const token = () => window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
  const rpc = (name, args = {}) => window.JLApi?.rpc?.(name, args);
  const array = (value) => Array.isArray(value) ? value : [];

  function requestId(item, prefix, index = 0) {
    return String(
      item?.id ?? item?.invite_id ?? item?.challenge_id ?? item?.room_id ??
      item?.code ?? item?.uuid ?? item?.created_at ?? `${prefix}-${index}`
    );
  }

  function requestName(item, fallback = 'Jogador') {
    return String(
      item?.other_name ?? item?.from_name ?? item?.challenger_name ??
      item?.host_name ?? item?.player_name ?? item?.creator_name ??
      item?.name ?? fallback
    ).trim() || fallback;
  }

  function isIncomingBoardInvite(item) {
    const status = String(item?.status || '').toLowerCase();
    const role = String(item?.role || '').toLowerCase();
    return status === 'pending' && ['target', 'incoming', 'recipient'].includes(role);
  }

  function setCount(id, value) {
    const el = document.getElementById(id);
    if (!el) return;
    const next = String(Math.max(0, Number(value) || 0));
    if (el.textContent !== next) el.textContent = next;
  }

  function applyCounts(direct, publicCount) {
    lastCounts.direct = Math.max(0, Number(direct) || 0);
    lastCounts.public = Math.max(0, Number(publicCount) || 0);
    lastCounts.ready = true;
    setCount('jlGlobalDirectCount', lastCounts.direct);
    setCount('jlGlobalPublicCount', lastCounts.public);
  }

  function installCountGuard() {
    countObserver?.disconnect?.();
    const direct = document.getElementById('jlGlobalDirectCount');
    const publicEl = document.getElementById('jlGlobalPublicCount');
    if (!direct && !publicEl) {
      setTimeout(installCountGuard, 250);
      return;
    }

    countObserver = new MutationObserver(() => {
      if (!lastCounts.ready) return;
      setCount('jlGlobalDirectCount', lastCounts.direct);
      setCount('jlGlobalPublicCount', lastCounts.public);
    });
    if (direct) countObserver.observe(direct, { childList: true, characterData: true, subtree: true });
    if (publicEl) countObserver.observe(publicEl, { childList: true, characterData: true, subtree: true });
  }

  function pushNotification(item) {
    const api = window.JLNotifications;
    if (!api?.push) return false;
    api.push(item);
    return true;
  }

  function bridgeDirectNotifications(boardInvites, ludoInvites) {
    boardInvites.forEach((invite, index) => {
      const id = requestId(invite, 'board', index);
      const name = requestName(invite);
      pushNotification({
        id: `request-board:${id}`,
        title: 'Convite individual',
        message: `${name} convidou você para jogar.`,
        type: 'invite',
        href: './tabuleiro.html#boardSocial',
        createdAt: invite?.created_at || invite?.updated_at || new Date().toISOString()
      });
    });

    ludoInvites.forEach((invite, index) => {
      const id = requestId(invite, 'ludo', index);
      const name = requestName(invite);
      pushNotification({
        id: `request-ludo:${id}`,
        title: 'Convite individual',
        message: `${name} convidou você para o Ludo.`,
        type: 'invite',
        href: './ludo.html#notificationCenter',
        createdAt: invite?.created_at || invite?.updated_at || new Date().toISOString()
      });
    });
  }

  function bridgePublicNotifications(challenges) {
    challenges.forEach((challenge, index) => {
      const id = requestId(challenge, 'public', index);
      const name = requestName(challenge);
      pushNotification({
        id: `request-public:${id}`,
        title: 'Pedido público',
        message: `${name} está à procura de jogadores.`,
        type: 'invite',
        href: './ludo.html#notificationCenter',
        createdAt: challenge?.created_at || challenge?.updated_at || new Date().toISOString()
      });
    });
  }

  async function safeRpc(name, args) {
    try {
      const result = rpc(name, args);
      return result && typeof result.then === 'function' ? await result : null;
    } catch {
      return null;
    }
  }

  async function refresh() {
    const current = token();
    if (!current || busy || !window.JLApi?.rpc) {
      if (!current) applyCounts(0, 0);
      return;
    }

    busy = true;
    try {
      const [status, publicRows, boardRows] = await Promise.all([
        safeRpc('jl_ludo_my_status', { p_token: current }),
        safeRpc('jl_ludo_public_challenges', { p_token: current }),
        safeRpc('jl_board_invites_feed', { p_token: current })
      ]);

      const boardFeed = array(boardRows);
      const incomingBoard = boardFeed.filter(isIncomingBoardInvite);

      const legacyInvites = array(status?.invites).filter((invite) => {
        const statusValue = String(invite?.status || 'pending').toLowerCase();
        const role = String(invite?.role || invite?.direction || 'target').toLowerCase();
        return !['accepted', 'declined', 'cancelled', 'expired', 'finished'].includes(statusValue) &&
          !['sender', 'source', 'outgoing', 'host'].includes(role);
      });

      const fallbackDirect = Number(status?.pending_invites_count ?? status?.invites_count);
      const ludoDirectCount = legacyInvites.length || (Number.isFinite(fallbackDirect) ? Math.max(0, fallbackDirect) : 0);

      const publicChallenges = Array.isArray(publicRows)
        ? publicRows
        : array(status?.public_challenges);
      const fallbackPublic = Number(status?.public_challenges_count ?? status?.public_count);
      const publicCount = publicChallenges.length || (Number.isFinite(fallbackPublic) ? Math.max(0, fallbackPublic) : 0);

      applyCounts(incomingBoard.length + ludoDirectCount, publicCount);
      bridgeDirectNotifications(incomingBoard, legacyInvites);
      bridgePublicNotifications(publicChallenges);
      window.JLNotifications?.refresh?.();
    } finally {
      busy = false;
    }
  }

  function start() {
    clearInterval(timer);
    void refresh();
    timer = setInterval(() => {
      if (document.visibilityState === 'visible') void refresh();
    }, POLL_MS);
  }

  const boot = () => {
    installCountGuard();
    start();
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') void refresh();
    });
    window.addEventListener('focus', refresh);
    window.addEventListener('pageshow', refresh);
    window.addEventListener('jl-player-session-changed', refresh);
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();