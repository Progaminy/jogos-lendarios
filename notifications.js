(() => {
  if (window.__JL_NOTIFICATIONS_SINGLETON__) return;
  window.__JL_NOTIFICATIONS_SINGLETON__ = true;

  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  const STORAGE_PREFIX = 'jl_notifications_v2_';
  const LEGACY_STORAGE_PREFIX = 'jl_notifications_v1_';
  const DEVICE_KEY = 'jl_notifications_device_enabled_v2';
  const LEGACY_DEVICE_KEY = 'jl_notifications_device_enabled_v1';
  const MAX_ITEMS = 80;
  const POLL_MS = 8000;
  const PUSH_POLL_MS = 30000;

  const ui = {
    root: null,
    button: null,
    badge: null,
    panel: null,
    list: null,
    deviceButton: null
  };

  let active = false;
  let pollTimer = null;
  let syncBusy = false;
  let swRegistration = null;
  let pushReady = false;
  let autoPermissionBusy = false;
  let autoPermissionAttempted = false;
  let sessionToken = window.JLSession?.getPlayerToken?.() || localStorage.getItem(TOKEN_KEY) || '';

  function token() {
    return window.JLSession?.getPlayerToken?.() || localStorage.getItem(TOKEN_KEY) || '';
  }

  function tokenHash(value) {
    let h = 2166136261;
    for (let i = 0; i < value.length; i += 1) {
      h ^= value.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(36);
  }

  function storageKey(prefix = STORAGE_PREFIX) {
    const t = token() || sessionToken;
    return t ? prefix + tokenHash(t) : '';
  }

  function migrateLegacyStorage() {
    const key = storageKey();
    const legacy = storageKey(LEGACY_STORAGE_PREFIX);
    if (!key || !legacy || localStorage.getItem(key) !== null) return;
    const value = localStorage.getItem(legacy);
    if (value !== null) localStorage.setItem(key, value);
  }

  function readItems() {
    migrateLegacyStorage();
    const key = storageKey();
    if (!key) return [];
    try {
      const parsed = JSON.parse(localStorage.getItem(key) || '[]');
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }

  function writeItems(items) {
    const key = storageKey();
    if (!key) return;
    try {
      const sorted = items.slice().sort((a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0));
      localStorage.setItem(key, JSON.stringify(sorted.slice(0, MAX_ITEMS)));
    } catch {}
  }

  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/[&<>'"]/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
    }[c]));
  }

  function formatWhen(value) {
    if (!value) return 'Agora';
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return 'Agora';
    return d.toLocaleString('pt-MZ', { dateStyle: 'short', timeStyle: 'short' });
  }

  function notificationActionLabel(item) {
    const href = String(item && item.href ? item.href : '').toLowerCase();
    if (href.includes('deposit')) return 'Ir para depósito';
    if (href.includes('withdraw')) return 'Ir para saque';
    if (href.includes('ludo')) return 'Abrir Ludo';
    if (href.includes('support')) return 'Abrir atendimento';
    return 'Abrir área relacionada';
  }

  function looksServerBacked(id) {
    return /^(ludo-invite|number-win|pair-win|ludo-win|follow|support|deposit-status|withdraw-status):/.test(String(id || ''));
  }

  function normalizeItem(input) {
    const now = new Date().toISOString();
    const id = String(input && input.id ? input.id : 'notice:' + Date.now() + ':' + Math.random().toString(36).slice(2, 8));
    return {
      id,
      serverId: input && input.serverId != null ? Number(input.serverId) : null,
      title: String(input && input.title ? input.title : 'Notificação'),
      message: String(input && input.message ? input.message : ''),
      type: String(input && input.type ? input.type : 'info'),
      href: input && input.href ? String(input.href) : '',
      createdAt: input && input.createdAt ? input.createdAt : now,
      read: Boolean(input && input.read),
      serverBacked: Boolean(input && input.serverBacked) || looksServerBacked(id)
    };
  }

  const rpc = (name, args = {}) => window.JLApi.rpc(name, args, { keepalive: true });

  async function pushService(path, options = {}) {
    if (!cfg.supabaseUrl) throw new Error('Serviço de notificações indisponível.');
    const headers = Object.assign({
      'Content-Type': 'application/json',
      Accept: 'application/json'
    }, cfg.supabaseKey ? { apikey: cfg.supabaseKey } : {});
    const response = await fetch(cfg.supabaseUrl + '/functions/v1/jogos-push' + path, Object.assign({
      headers,
      cache: 'no-store'
    }, options));
    const raw = await response.text();
    let data = null;
    try { data = raw ? JSON.parse(raw) : null; } catch { data = raw; }
    if (!response.ok) throw new Error((data && (data.error || data.message)) || ('Erro ' + response.status));
    return data;
  }

  function injectStyle() {
    if (document.getElementById('jlNotificationsStyle')) return;
    const style = document.createElement('style');
    style.id = 'jlNotificationsStyle';
    style.textContent = [
      '.jl-notify-wrap{position:relative;display:inline-flex;align-items:center}',
      '.jl-notify-button{position:relative;display:grid;place-items:center;width:40px;height:40px;padding:0;border:1px solid rgba(255,255,255,.13);border-radius:12px;background:rgba(255,255,255,.055);color:inherit;cursor:pointer;font:inherit}',
      '.jl-notify-button:hover{filter:brightness(1.12)}',
      '.jl-notify-badge{position:absolute;right:-6px;top:-7px;display:grid;place-items:center;min-width:20px;height:20px;padding:0 5px;border-radius:999px;background:#ef5967;color:#fff;border:2px solid #07101d;font-size:.66rem;font-weight:950;line-height:1}',
      '.jl-notify-panel{position:absolute;z-index:130;right:0;top:calc(100% + 10px);width:min(390px,calc(100vw - 20px));max-height:min(560px,78vh);display:grid;grid-template-rows:auto minmax(0,1fr) auto;border:1px solid rgba(255,255,255,.12);border-radius:16px;background:#0d1b2c;box-shadow:0 24px 70px rgba(0,0,0,.55);overflow:hidden}',
      '.jl-notify-panel.hidden,.jl-notify-wrap.hidden{display:none!important}',
      '.jl-notify-head{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:15px;border-bottom:1px solid rgba(255,255,255,.09)}',
      '.jl-notify-head strong{font-size:.98rem}.jl-notify-head small{display:block;color:#91a4bd;margin-top:2px}',
      '.jl-notify-head-actions{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}',
      '.jl-notify-mini{border:1px solid rgba(255,255,255,.12);border-radius:9px;background:transparent;color:#dce6f4;padding:6px 8px;font:inherit;font-size:.72rem;font-weight:800;cursor:pointer}',
      '.jl-notify-mini:disabled{opacity:.55;cursor:default}',
      '.jl-notify-list{overflow:auto;padding:8px}',
      '.jl-notify-empty{padding:28px 16px;text-align:center;color:#91a4bd}',
      '.jl-notify-item{display:grid;grid-template-columns:10px minmax(0,1fr);gap:10px;padding:12px;border-radius:12px;border:1px solid transparent;color:inherit;text-decoration:none;cursor:pointer}',
      '.jl-notify-item:hover{background:rgba(255,255,255,.045)}',
      '.jl-notify-item.unread{background:rgba(76,139,245,.09);border-color:rgba(76,139,245,.2)}',
      '.jl-notify-dot{width:8px;height:8px;margin-top:7px;border-radius:50%;background:#6f829d}.jl-notify-item.unread .jl-notify-dot{background:#f4bd42;box-shadow:0 0 0 4px rgba(244,189,66,.10)}',
      '.jl-notify-copy strong{display:block;color:#f4f7fb;font-size:.86rem}.jl-notify-copy p{margin:3px 0 0;color:#c7d3e2;font-size:.78rem;line-height:1.38}.jl-notify-copy time{display:block;margin-top:5px;color:#8195ae;font-size:.68rem}',
      '.jl-notify-actions{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}.jl-notify-open{border-color:rgba(244,189,66,.35);color:#ffdb78;background:rgba(244,189,66,.07)}',
      '.jl-notify-foot{padding:10px 12px;border-top:1px solid rgba(255,255,255,.09);display:flex;align-items:center;justify-content:space-between;gap:10px;color:#91a4bd;font-size:.7rem}',
      '.jl-notify-device.enabled{border-color:rgba(53,201,133,.45);color:#8df1bb}',
      '@media(max-width:600px){.jl-notify-panel{position:fixed;left:10px;right:10px;top:68px;width:auto;max-height:calc(100dvh - 82px)}.jl-notify-button{width:38px;height:38px}.jl-notify-head{align-items:flex-start}.jl-notify-head-actions{max-width:150px}}'
    ].join('');
    document.head.appendChild(style);
  }

  function createUi() {
    if (ui.root && ui.root.isConnected) return true;
    const host = document.querySelector('.top-actions');
    if (!host) return false;

    injectStyle();
    const root = document.createElement('div');
    root.className = 'jl-notify-wrap hidden';
    root.innerHTML =
      '<button class="jl-notify-button" type="button" aria-label="Notificações" aria-expanded="false">' +
        '<span aria-hidden="true">🔔</span><span class="jl-notify-badge hidden">0</span>' +
      '</button>' +
      '<section class="jl-notify-panel hidden" role="dialog" aria-label="Notificações">' +
        '<div class="jl-notify-head">' +
          '<div><strong>Notificações</strong><small class="jl-notify-summary">Sem notificações novas</small></div>' +
          '<div class="jl-notify-head-actions">' +
            '<button class="jl-notify-mini" type="button" data-jl-notify-read>Marcar lidas</button>' +
            '<button class="jl-notify-mini" type="button" data-jl-notify-clear>Limpar</button>' +
          '</div>' +
        '</div>' +
        '<div class="jl-notify-list"></div>' +
        '<div class="jl-notify-foot">' +
          '<span>Jogos Lendários</span>' +
          '<button class="jl-notify-mini jl-notify-device" type="button">Ativar no aparelho</button>' +
        '</div>' +
      '</section>';

    const account = host.querySelector('.account-popover-wrap');
    if (account) host.insertBefore(root, account);
    else host.appendChild(root);

    ui.root = root;
    ui.button = root.querySelector('.jl-notify-button');
    ui.badge = root.querySelector('.jl-notify-badge');
    ui.panel = root.querySelector('.jl-notify-panel');
    ui.list = root.querySelector('.jl-notify-list');
    ui.deviceButton = root.querySelector('.jl-notify-device');

    ui.button.addEventListener('click', (event) => {
      event.stopPropagation();
      const open = ui.panel.classList.contains('hidden');
      ui.panel.classList.toggle('hidden', !open);
      ui.button.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (open) {
        render();
        syncServer();
      }
    });

    root.querySelector('[data-jl-notify-read]').addEventListener('click', markAllRead);
    root.querySelector('[data-jl-notify-clear]').addEventListener('click', clearAll);
    ui.deviceButton.addEventListener('click', toggleDeviceNotifications);
    ui.list.addEventListener('click', (event) => {
      const item = event.target.closest('[data-jl-notify-id]');
      if (!item) return;
      markRead(item.dataset.jlNotifyId);

      const action = event.target.closest('[data-jl-notify-open]');
      if (!action) return;

      event.preventDefault();
      const href = action.dataset.jlNotifyOpen || '';
      if (href) window.location.href = href;
    });

    document.addEventListener('click', (event) => {
      if (!ui.root || ui.panel.classList.contains('hidden')) return;
      if (event.target.closest('.jl-notify-wrap')) return;
      closePanel();
    });

    return true;
  }

  function closePanel() {
    if (!ui.panel) return;
    ui.panel.classList.add('hidden');
    if (ui.button) ui.button.setAttribute('aria-expanded', 'false');
  }

  function updateDeviceButton(message = '') {
    if (!ui.deviceButton) return;
    if (!('Notification' in window) || !('serviceWorker' in navigator) || !('PushManager' in window)) {
      ui.deviceButton.textContent = 'Não suportado';
      ui.deviceButton.disabled = true;
      return;
    }

    const enabledPreference =
      localStorage.getItem(DEVICE_KEY) === '1' ||
      (localStorage.getItem(DEVICE_KEY) === null && localStorage.getItem(LEGACY_DEVICE_KEY) === '1');
    if (enabledPreference && localStorage.getItem(DEVICE_KEY) === null) localStorage.setItem(DEVICE_KEY, '1');

    const enabled = enabledPreference && Notification.permission === 'granted' && pushReady;
    ui.deviceButton.disabled = false;
    ui.deviceButton.classList.toggle('enabled', enabled);
    if (message) ui.deviceButton.textContent = message;
    else if (enabled) ui.deviceButton.textContent = 'Avisos no aparelho: ligados';
    else if (Notification.permission === 'denied') ui.deviceButton.textContent = 'Bloqueado no navegador';
    else if (enabledPreference && Notification.permission === 'granted') ui.deviceButton.textContent = 'Reativar avisos';
    else ui.deviceButton.textContent = 'Ativar no aparelho';
  }

  function render() {
    if (!createUi()) return;
    const enabled = active && Boolean(token());
    ui.root.classList.toggle('hidden', !enabled);
    if (!enabled) {
      closePanel();
      return;
    }

    const items = readItems();
    const unread = items.filter((item) => !item.read).length;
    ui.badge.textContent = unread > 99 ? '99+' : String(unread);
    ui.badge.classList.toggle('hidden', unread === 0);
    const summary = ui.root.querySelector('.jl-notify-summary');
    if (summary) summary.textContent = unread ? String(unread) + ' não lida' + (unread === 1 ? '' : 's') : 'Sem notificações novas';

    ui.list.innerHTML = items.length ? items.map((item) => {
      const action = item.href
        ? '<span class="jl-notify-actions"><button type="button" class="jl-notify-mini jl-notify-open" data-jl-notify-open="' + escapeHtml(item.href) + '">' + escapeHtml(notificationActionLabel(item)) + '</button></span>'
        : '';
      return '<div class="jl-notify-item' + (item.read ? '' : ' unread') + '" data-jl-notify-id="' + escapeHtml(item.id) + '">' +
        '<span class="jl-notify-dot" aria-hidden="true"></span>' +
        '<span class="jl-notify-copy"><strong>' + escapeHtml(item.title || 'Notificação') + '</strong><p>' + escapeHtml(item.message || '') + '</p><time>' + escapeHtml(formatWhen(item.createdAt)) + '</time>' + action + '</span>' +
      '</div>';
    }).join('') : '<div class="jl-notify-empty">Ainda não há notificações.</div>';

    updateDeviceButton();
  }

  async function persistRead(item) {
    if (!item || !item.serverBacked || !sessionToken) return;
    const args = {
      p_token: sessionToken,
      p_notification_id: item.serverId || null,
      p_source_key: item.serverId ? null : item.id,
      p_all: false
    };
    try { await rpc('jl_notifications_mark_read', args); } catch {}
  }

  function push(input) {
    if (!token()) return false;
    const item = normalizeItem(input || {});
    const items = readItems();
    const existing = items.findIndex((entry) => entry.id === item.id);
    if (existing >= 0) {
      items[existing] = Object.assign({}, items[existing], item, { read: Boolean(items[existing].read || item.read) });
      writeItems(items);
      render();
      return false;
    }

    items.unshift(item);
    writeItems(items);
    render();

    if (!(pushReady && item.serverBacked)) maybeDeviceNotification(item);
    return true;
  }

  function markRead(id) {
    const items = readItems();
    let changed = false;
    let selected = null;
    for (const item of items) {
      if (item.id === id) {
        selected = item;
        if (!item.read) {
          item.read = true;
          changed = true;
        }
      }
    }
    if (changed) writeItems(items);
    render();
    if (selected) persistRead(selected);
  }

  async function markAllRead() {
    const items = readItems().map((item) => Object.assign({}, item, { read: true }));
    writeItems(items);
    render();
    if (!sessionToken) return;
    try {
      await rpc('jl_notifications_mark_read', {
        p_token: sessionToken,
        p_notification_id: null,
        p_source_key: null,
        p_all: true
      });
    } catch {}
  }

  async function clearAll() {
    writeItems([]);
    render();
    if (!sessionToken) return;
    try { await rpc('jl_notifications_clear', { p_token: sessionToken }); } catch {}
  }

  async function syncServer() {
    if (!active || !sessionToken || syncBusy || document.visibilityState !== 'visible') return;
    syncBusy = true;
    try {
      const rows = await rpc('jl_notifications_feed', { p_token: sessionToken, p_limit: MAX_ITEMS });
      if (!Array.isArray(rows)) return;

      const previous = readItems();
      const oldById = new Map(previous.map((item) => [String(item.id), item]));
      const serverIds = new Set();
      const newUnread = [];
      const needRemoteRead = [];

      const serverItems = rows.map((row) => {
        const item = normalizeItem(Object.assign({}, row, { serverBacked: true }));
        serverIds.add(item.id);
        const old = oldById.get(item.id);
        if (old && old.read && !item.read) {
          item.read = true;
          needRemoteRead.push(item);
        }
        if (!old && !item.read) newUnread.push(item);
        return item;
      });

      const localOnly = previous.filter((item) => !item.serverBacked && !serverIds.has(String(item.id)));
      writeItems(serverItems.concat(localOnly));
      render();

      for (const item of needRemoteRead) persistRead(item);
      if (!pushReady) for (const item of newUnread) maybeDeviceNotification(item);
    } catch (error) {
      console.warn('notification sync', error && error.message ? error.message : error);
    } finally {
      syncBusy = false;
    }
  }

  function startPolling() {
    stopPolling();
    if (window.JLLudoSync?.register) {
      window.JLLudoSync.register('notifications', syncServer, {
        interval: () => pushReady ? PUSH_POLL_MS : POLL_MS,
        when: () => active && Boolean(sessionToken),
        visibleOnly: true,
        immediate: false
      });
      return;
    }
    pollTimer = setInterval(syncServer, POLL_MS);
  }

  function stopPolling() {
    window.JLLudoSync?.unregister?.('notifications');
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = null;
  }

  async function ensureServiceWorker() {
    if (!('serviceWorker' in navigator)) throw new Error('Service Worker não suportado.');
    if (swRegistration) return swRegistration;
    swRegistration = await navigator.serviceWorker.register('./sw.js?v=20260927-3', { scope: './' });
    await navigator.serviceWorker.ready;
    return swRegistration;
  }

  function urlBase64ToUint8Array(value) {
    const padding = '='.repeat((4 - value.length % 4) % 4);
    const base64 = (value + padding).replace(/-/g, '+').replace(/_/g, '/');
    const raw = atob(base64);
    const output = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i += 1) output[i] = raw.charCodeAt(i);
    return output;
  }

  async function registerPushSubscription(requireNew = false) {
    if (!sessionToken) throw new Error('Entre na sua conta primeiro.');
    const registration = await ensureServiceWorker();
    let subscription = await registration.pushManager.getSubscription();

    if (!subscription || requireNew) {
      if (requireNew && subscription) {
        try { await subscription.unsubscribe(); } catch {}
        subscription = null;
      }
      const keyData = await pushService('/public-key', { method: 'GET' });
      if (!keyData || !keyData.publicKey) throw new Error('Chave de notificações indisponível.');
      subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(String(keyData.publicKey))
      });
    }

    await pushService('/subscribe', {
      method: 'POST',
      body: JSON.stringify({
        token: sessionToken,
        subscription: subscription.toJSON()
      })
    });

    pushReady = true;
    localStorage.setItem(DEVICE_KEY, '1');
    updateDeviceButton();
    return subscription;
  }

  async function unregisterServerSubscription(forToken, browserUnsubscribe) {
    if (!forToken || !('serviceWorker' in navigator)) return;
    try {
      const registration = await ensureServiceWorker();
      const subscription = await registration.pushManager.getSubscription();
      if (!subscription) return;
      await pushService('/unsubscribe', {
        method: 'POST',
        body: JSON.stringify({ token: forToken, endpoint: subscription.endpoint })
      });
      if (browserUnsubscribe) await subscription.unsubscribe();
    } catch {}
  }

  async function disableDeviceNotifications() {
    const old = sessionToken;
    ui.deviceButton.disabled = true;
    updateDeviceButton('A desligar…');
    await unregisterServerSubscription(old, true);
    pushReady = false;
    localStorage.setItem(DEVICE_KEY, '0');
    localStorage.setItem(LEGACY_DEVICE_KEY, '0');
    updateDeviceButton('Ativar no aparelho');
  }

  async function enableDeviceNotifications() {
    if (!('Notification' in window) || !('serviceWorker' in navigator) || !('PushManager' in window)) {
      return updateDeviceButton('Não suportado');
    }
    if (Notification.permission === 'denied') return updateDeviceButton('Bloqueado no navegador');

    ui.deviceButton.disabled = true;
    updateDeviceButton('A ativar…');
    try {
      const permission = Notification.permission === 'granted' ? 'granted' : await Notification.requestPermission();
      if (permission !== 'granted') {
        localStorage.setItem(DEVICE_KEY, '0');
        return updateDeviceButton('Permissão não concedida');
      }
      await registerPushSubscription(false);
      updateDeviceButton('Avisos no aparelho: ligados');
    } catch (error) {
      pushReady = false;
      updateDeviceButton('Tentar novamente');
      console.warn('push enable', error && error.message ? error.message : error);
    } finally {
      ui.deviceButton.disabled = false;
    }
  }

  async function toggleDeviceNotifications() {
    const enabled = localStorage.getItem(DEVICE_KEY) === '1' && Notification.permission === 'granted' && pushReady;
    if (enabled) await disableDeviceNotifications();
    else await enableDeviceNotifications();
  }

  async function autoEnableDeviceNotifications() {
    if (!active || !sessionToken || autoPermissionBusy) return;
    if (!('Notification' in window) || !('serviceWorker' in navigator) || !('PushManager' in window)) {
      updateDeviceButton('Não suportado');
      return;
    }
    if (Notification.permission === 'denied') {
      updateDeviceButton('Bloqueado no navegador');
      return;
    }

    autoPermissionBusy = true;
    try {
      if (Notification.permission === 'default') {
        if (autoPermissionAttempted) return;
        autoPermissionAttempted = true;
        const permission = await Notification.requestPermission();
        if (permission !== 'granted') {
          updateDeviceButton('Permissão não concedida');
          return;
        }
      }
      await registerPushSubscription(false);
      updateDeviceButton('Avisos no aparelho: ligados');
    } catch (error) {
      pushReady = false;
      updateDeviceButton();
      console.warn('push auto enable', error && error.message ? error.message : error);
    } finally {
      autoPermissionBusy = false;
    }
  }

  async function silentPushSync() {
    if (!active || !sessionToken) return;
    const enabledPreference =
      localStorage.getItem(DEVICE_KEY) === '1' ||
      (localStorage.getItem(DEVICE_KEY) === null && localStorage.getItem(LEGACY_DEVICE_KEY) === '1');
    if (!enabledPreference || !('Notification' in window) || Notification.permission !== 'granted') {
      pushReady = false;
      updateDeviceButton();
      return;
    }

    try {
      const registration = await ensureServiceWorker();
      const subscription = await registration.pushManager.getSubscription();
      if (!subscription) {
        pushReady = false;
        updateDeviceButton();
        return;
      }
      await pushService('/subscribe', {
        method: 'POST',
        body: JSON.stringify({ token: sessionToken, subscription: subscription.toJSON() })
      });
      pushReady = true;
    } catch {
      pushReady = false;
    }
    updateDeviceButton();
  }

  async function maybeDeviceNotification(item) {
    if (!('Notification' in window) || Notification.permission !== 'granted') return;
    const enabled =
      localStorage.getItem(DEVICE_KEY) === '1' ||
      (localStorage.getItem(DEVICE_KEY) === null && localStorage.getItem(LEGACY_DEVICE_KEY) === '1');
    if (!enabled) return;
    if (document.visibilityState === 'visible' && document.hasFocus()) return;

    try {
      const registration = await ensureServiceWorker();
      await registration.showNotification('Jogos Lendários · ' + item.title, {
        body: item.message,
        tag: item.id,
        renotify: false,
        data: { id: item.id, href: item.href || './index.html' }
      });
    } catch {
      try {
        const n = new Notification('Jogos Lendários · ' + item.title, {
          body: item.message,
          tag: item.id,
          renotify: false
        });
        n.onclick = () => {
          window.focus();
          markRead(item.id);
          if (ui.panel) {
            ui.panel.classList.remove('hidden');
            ui.button?.setAttribute('aria-expanded', 'true');
            render();
          }
          n.close();
        };
      } catch {}
    }
  }

  function setActive(value = true) {
    const next = Boolean(value);
    const currentToken = token();
    const sameSession = next && active && currentToken && currentToken === sessionToken;

    if (sameSession) {
      render();
      return;
    }

    if (next && currentToken) sessionToken = currentToken;
    if (!next && sessionToken) {
      const oldToken = sessionToken;
      unregisterServerSubscription(oldToken, false);
    }

    active = next;
    if (active) {
      startPolling();
      syncServer();
      autoEnableDeviceNotifications();
    } else {
      stopPolling();
      pushReady = false;
    }
    render();
  }

  function refresh() {
    render();
    syncServer();
  }

  window.JLNotifications = Object.freeze({
    push,
    markRead,
    markAllRead,
    clearAll,
    setActive,
    refresh,
    sync: syncServer
  });

  const boot = () => {
    createUi();
    sessionToken = token();
    active = Boolean(sessionToken);
    render();
    if (active) {
      startPolling();
      syncServer();
      autoEnableDeviceNotifications();
    }
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();

  window.addEventListener('storage', (event) => {
    if (event.key === TOKEN_KEY) {
      const nextToken = token();
      if (nextToken) {
        sessionToken = nextToken;
        setActive(true);
      } else {
        setActive(false);
      }
      return;
    }
    if ((event.key && event.key.startsWith(STORAGE_PREFIX)) || event.key === DEVICE_KEY) render();
  });

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && active) {
      render();
      syncServer();
      silentPushSync();
    }
  });

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.addEventListener('message', (event) => {
      const data = event.data || {};
      if (data.type !== 'jl-notification-open') return;
      if (data.id) markRead(String(data.id));
      if (ui.panel) {
        ui.panel.classList.remove('hidden');
        ui.button?.setAttribute('aria-expanded', 'true');
        render();
      }
    });
  }
})();