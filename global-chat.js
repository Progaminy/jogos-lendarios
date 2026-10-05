(() => {
  'use strict';

  const POLL_OPEN_MS = 3500;
  const POLL_CLOSED_MS = 9000;
  const HISTORY_LIMIT = 80;

  const state = {
    metric: null,
    badge: null,
    overlay: null,
    messages: null,
    input: null,
    send: null,
    status: null,
    open: false,
    busy: false,
    sending: false,
    lastFetchedId: 0,
    renderedIds: new Set(),
    timer: 0,
    stripObserver: null
  };

  const token = () => {
    try {
      return window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
    } catch {
      return '';
    }
  };

  function rpc(name, args) {
    if (!window.JLApi?.rpc) return Promise.reject(new Error('Serviço de chat indisponível.'));
    return window.JLApi.rpc(name, args);
  }

  function requireOk(data) {
    if (!data?.ok) throw new Error(data?.error || 'Não foi possível concluir a operação.');
    return data;
  }

  function openLogin() {
    const modal = document.getElementById('authModal');
    if (modal) {
      modal.classList.remove('hidden');
      document.body.classList.add('modal-open');
      setTimeout(() => {
        document.getElementById('loginTab')?.click();
        document.getElementById('loginPhone')?.focus?.();
      }, 0);
      return;
    }
    location.href = './index.html#login';
  }

  function formatTime(value) {
    const date = new Date(value || Date.now());
    if (Number.isNaN(date.getTime())) return '';
    return date.toLocaleTimeString('pt-MZ', { hour: '2-digit', minute: '2-digit' });
  }

  function setBadge(value) {
    const count = Math.max(0, Number(value) || 0);
    if (!state.badge) return;
    state.badge.textContent = count > 99 ? '99+' : String(count);
    state.metric?.setAttribute('aria-label', count > 0 ? `Chat, ${count} mensagens não lidas` : 'Chat');
  }

  function setStatus(message = '', error = false) {
    if (!state.status) return;
    state.status.textContent = String(message || '');
    state.status.classList.toggle('error', Boolean(error));
  }

  function setGridToFour(strip) {
    if (!strip) return;
    strip.style.setProperty('grid-template-columns', 'repeat(4,minmax(0,1fr))', 'important');
  }

  function ensureMetric() {
    const strip = document.getElementById('ludoStatusStrip') || document.getElementById('jlGlobalStatusStrip');
    if (!strip) return false;

    setGridToFour(strip);

    let metric = document.getElementById('jlGlobalChatMetric');
    if (!metric) {
      metric = document.createElement('button');
      metric.id = 'jlGlobalChatMetric';
      metric.className = 'status-metric';
      metric.type = 'button';
      metric.setAttribute('aria-label', 'Chat');
      metric.setAttribute('aria-expanded', 'false');
      metric.innerHTML = '<span class="status-icon" aria-hidden="true">💬</span><strong id="jlGlobalChatUnread" aria-live="polite">0</strong>';
      strip.appendChild(metric);
    }

    state.metric = metric;
    state.badge = metric.querySelector('#jlGlobalChatUnread') || document.getElementById('jlGlobalChatUnread');
    if (metric.dataset.jlGlobalChatBound !== '1') {
      metric.dataset.jlGlobalChatBound = '1';
      metric.addEventListener('click', (event) => {
        event.preventDefault();
        event.stopPropagation();
        if (!token()) {
          openLogin();
          return;
        }
        if (state.open) closeChat();
        else openChat();
      });
    }
    return true;
  }

  function watchForStrip() {
    if (ensureMetric()) return;
    if (state.stripObserver) return;
    state.stripObserver = new MutationObserver(() => {
      if (!ensureMetric()) return;
      state.stripObserver?.disconnect();
      state.stripObserver = null;
    });
    state.stripObserver.observe(document.documentElement, { childList: true, subtree: true });
    setTimeout(() => {
      state.stripObserver?.disconnect();
      state.stripObserver = null;
    }, 12000);
  }

  function createPanel() {
    if (state.overlay?.isConnected) return;

    const overlay = document.createElement('div');
    overlay.id = 'jlGlobalChatOverlay';
    overlay.className = 'jl-global-chat-overlay hidden';
    overlay.setAttribute('aria-hidden', 'true');
    overlay.innerHTML = `
      <section class="jl-global-chat-panel" role="dialog" aria-modal="true" aria-labelledby="jlGlobalChatTitle">
        <header class="jl-global-chat-head">
          <div class="jl-global-chat-title">
            <strong id="jlGlobalChatTitle">Chat dos Jogos Lendários</strong>
            <small>Conversa entre jogadores</small>
          </div>
          <button class="jl-global-chat-close" type="button" aria-label="Fechar chat">×</button>
        </header>
        <div class="jl-global-chat-messages" id="jlGlobalChatMessages" aria-live="polite">
          <div class="jl-global-chat-empty">Ainda não há mensagens. Seja o primeiro a conversar.</div>
        </div>
        <form class="jl-global-chat-composer" id="jlGlobalChatForm">
          <input class="jl-global-chat-input" id="jlGlobalChatInput" maxlength="500" autocomplete="off" placeholder="Escreva uma mensagem…" aria-label="Mensagem">
          <button class="jl-global-chat-send" id="jlGlobalChatSend" type="submit">Enviar</button>
          <small class="jl-global-chat-status" id="jlGlobalChatStatus" role="status" aria-live="polite"></small>
        </form>
      </section>`;

    document.body.appendChild(overlay);
    state.overlay = overlay;
    state.messages = overlay.querySelector('#jlGlobalChatMessages');
    state.input = overlay.querySelector('#jlGlobalChatInput');
    state.send = overlay.querySelector('#jlGlobalChatSend');
    state.status = overlay.querySelector('#jlGlobalChatStatus');

    overlay.querySelector('.jl-global-chat-close')?.addEventListener('click', closeChat);
    overlay.addEventListener('click', (event) => {
      if (event.target === overlay) closeChat();
    });
    overlay.querySelector('#jlGlobalChatForm')?.addEventListener('submit', sendMessage);
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && state.open) closeChat();
    });
  }

  function clearMessages() {
    if (!state.messages) return;
    state.messages.textContent = '';
    state.renderedIds.clear();
  }

  function showEmptyIfNeeded() {
    if (!state.messages || state.messages.children.length) return;
    const empty = document.createElement('div');
    empty.className = 'jl-global-chat-empty';
    empty.textContent = 'Ainda não há mensagens. Seja o primeiro a conversar.';
    state.messages.appendChild(empty);
  }

  function removeEmpty() {
    state.messages?.querySelector('.jl-global-chat-empty')?.remove();
  }

  function renderMessage(message) {
    if (!state.messages) return;
    const id = Number(message?.id) || 0;
    if (id && state.renderedIds.has(id)) return;
    if (id) state.renderedIds.add(id);

    removeEmpty();
    const item = document.createElement('article');
    item.className = `jl-global-chat-message${message?.is_mine ? ' mine' : ''}`;
    if (id) item.dataset.messageId = String(id);

    const meta = document.createElement('div');
    meta.className = 'jl-global-chat-meta';
    const name = document.createElement('strong');
    name.className = 'jl-global-chat-name';
    name.textContent = String(message?.username || 'Jogador');
    const time = document.createElement('time');
    time.className = 'jl-global-chat-time';
    time.dateTime = String(message?.created_at || '');
    time.textContent = formatTime(message?.created_at);
    meta.append(name, time);

    const text = document.createElement('p');
    text.className = 'jl-global-chat-text';
    text.textContent = String(message?.message || '');
    item.append(meta, text);
    state.messages.appendChild(item);
    if (id > state.lastFetchedId) state.lastFetchedId = id;
  }

  function renderMessages(messages, replace = false) {
    if (replace) clearMessages();
    const list = Array.isArray(messages) ? messages : [];
    list.forEach(renderMessage);
    showEmptyIfNeeded();
    if (state.open) requestAnimationFrame(() => {
      if (state.messages) state.messages.scrollTop = state.messages.scrollHeight;
    });
  }

  async function markRead(lastId) {
    const current = token();
    if (!current) return;
    try {
      const data = requireOk(await rpc('jl_global_chat_mark_read', {
        p_token: current,
        p_last_id: Math.max(0, Number(lastId) || 0)
      }));
      setBadge(data.unread || 0);
    } catch {}
  }

  async function loadHistory() {
    const current = token();
    if (!current) return;
    state.busy = true;
    setStatus('Carregando…');
    try {
      const data = requireOk(await rpc('jl_global_chat_list', {
        p_token: current,
        p_after_id: 0,
        p_limit: HISTORY_LIMIT
      }));
      state.lastFetchedId = Math.max(0, Number(data.latest_id) || 0);
      renderMessages(data.messages, true);
      setBadge(data.unread || 0);
      await markRead(state.lastFetchedId);
      setStatus('');
    } catch (error) {
      setStatus(error?.message || 'Não foi possível carregar o chat.', true);
    } finally {
      state.busy = false;
    }
  }

  async function poll() {
    clearTimeout(state.timer);
    const current = token();
    if (!current || state.busy || document.hidden) {
      schedulePoll();
      return;
    }

    state.busy = true;
    try {
      const afterId = state.open ? state.lastFetchedId : Math.max(0, state.lastFetchedId);
      const data = requireOk(await rpc('jl_global_chat_list', {
        p_token: current,
        p_after_id: afterId,
        p_limit: state.open ? 100 : 1
      }));
      const latestId = Math.max(0, Number(data.latest_id) || 0);
      if (state.open) {
        renderMessages(data.messages, false);
        state.lastFetchedId = Math.max(state.lastFetchedId, latestId);
        await markRead(state.lastFetchedId);
      } else {
        state.lastFetchedId = Math.max(state.lastFetchedId, latestId);
        setBadge(data.unread || 0);
      }
    } catch {
    } finally {
      state.busy = false;
      schedulePoll();
    }
  }

  function schedulePoll() {
    clearTimeout(state.timer);
    state.timer = setTimeout(poll, state.open ? POLL_OPEN_MS : POLL_CLOSED_MS);
  }

  async function refreshBadge() {
    const current = token();
    if (!current) {
      setBadge(0);
      state.lastFetchedId = 0;
      schedulePoll();
      return;
    }
    if (state.busy) return;
    state.busy = true;
    try {
      const data = requireOk(await rpc('jl_global_chat_list', {
        p_token: current,
        p_after_id: Math.max(0, state.lastFetchedId),
        p_limit: 1
      }));
      state.lastFetchedId = Math.max(state.lastFetchedId, Number(data.latest_id) || 0);
      setBadge(data.unread || 0);
    } catch {
      setBadge(0);
    } finally {
      state.busy = false;
      schedulePoll();
    }
  }

  async function openChat() {
    if (!token()) {
      openLogin();
      return;
    }
    createPanel();
    state.open = true;
    state.overlay.classList.remove('hidden');
    state.overlay.setAttribute('aria-hidden', 'false');
    document.body.classList.add('jl-global-chat-open');
    state.metric?.setAttribute('aria-expanded', 'true');
    await loadHistory();
    state.input?.focus();
    schedulePoll();
  }

  function closeChat() {
    state.open = false;
    state.overlay?.classList.add('hidden');
    state.overlay?.setAttribute('aria-hidden', 'true');
    document.body.classList.remove('jl-global-chat-open');
    state.metric?.setAttribute('aria-expanded', 'false');
    setStatus('');
    schedulePoll();
  }

  async function sendMessage(event) {
    event?.preventDefault?.();
    const current = token();
    const text = String(state.input?.value || '').trim();
    if (!current) {
      closeChat();
      openLogin();
      return;
    }
    if (!text || state.sending) return;

    state.sending = true;
    if (state.send) state.send.disabled = true;
    if (state.input) state.input.disabled = true;
    setStatus('Enviando…');
    try {
      const data = requireOk(await rpc('jl_global_chat_send', {
        p_token: current,
        p_message: text
      }));
      if (state.input) state.input.value = '';
      renderMessage(data.message);
      await markRead(state.lastFetchedId);
      setStatus('');
    } catch (error) {
      setStatus(error?.message || 'Não foi possível enviar a mensagem.', true);
    } finally {
      state.sending = false;
      if (state.send) state.send.disabled = false;
      if (state.input) {
        state.input.disabled = false;
        state.input.focus();
      }
      schedulePoll();
    }
  }

  function resetSession(authenticated) {
    clearTimeout(state.timer);
    state.lastFetchedId = 0;
    state.renderedIds.clear();
    setBadge(0);
    if (!authenticated) closeChat();
    refreshBadge();
  }

  function init() {
    watchForStrip();
    createPanel();
    refreshBadge();
    window.addEventListener('jl-player-session-changed', (event) => resetSession(Boolean(event.detail?.authenticated)));
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') refreshBadge();
      else clearTimeout(state.timer);
    });
  }

  window.JLGlobalChat = Object.freeze({
    open: openChat,
    close: closeChat,
    refresh: refreshBadge
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, { once: true });
  else init();
})();
