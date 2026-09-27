(() => {
  'use strict';

  const TOKEN_KEY = 'jl_player_token';
  const STORAGE_PREFIX = 'jl_notifications_v1_';
  const DEVICE_KEY = 'jl_notifications_device_enabled_v1';
  const MAX_ITEMS = 80;

  const ui = {
    root: null,
    button: null,
    badge: null,
    panel: null,
    list: null,
    deviceButton: null
  };

  let active = false;

  function token() {
    return localStorage.getItem(TOKEN_KEY) || '';
  }

  function tokenHash(value) {
    let h = 2166136261;
    for (let i = 0; i < value.length; i += 1) {
      h ^= value.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(36);
  }

  function storageKey() {
    const t = token();
    return t ? `${STORAGE_PREFIX}${tokenHash(t)}` : '';
  }

  function readItems() {
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
      localStorage.setItem(key, JSON.stringify(items.slice(0, MAX_ITEMS)));
    } catch {}
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
    }[c]));
  }

  function formatWhen(value) {
    if (!value) return 'Agora';
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return 'Agora';
    return d.toLocaleString('pt-MZ', { dateStyle: 'short', timeStyle: 'short' });
  }

  function injectStyle() {
    if (document.getElementById('jlNotificationsStyle')) return;
    const style = document.createElement('style');
    style.id = 'jlNotificationsStyle';
    style.textContent = `
      .jl-notify-wrap{position:relative;display:inline-flex;align-items:center}
      .jl-notify-button{position:relative;display:grid;place-items:center;width:40px;height:40px;padding:0;border:1px solid rgba(255,255,255,.13);border-radius:12px;background:rgba(255,255,255,.055);color:inherit;cursor:pointer;font:inherit}
      .jl-notify-button:hover{filter:brightness(1.12)}
      .jl-notify-badge{position:absolute;right:-6px;top:-7px;display:grid;place-items:center;min-width:20px;height:20px;padding:0 5px;border-radius:999px;background:#ef5967;color:#fff;border:2px solid #07101d;font-size:.66rem;font-weight:950;line-height:1}
      .jl-notify-panel{position:absolute;z-index:130;right:0;top:calc(100% + 10px);width:min(390px,calc(100vw - 20px));max-height:min(560px,78vh);display:grid;grid-template-rows:auto minmax(0,1fr) auto;border:1px solid rgba(255,255,255,.12);border-radius:16px;background:#0d1b2c;box-shadow:0 24px 70px rgba(0,0,0,.55);overflow:hidden}
      .jl-notify-panel.hidden,.jl-notify-wrap.hidden{display:none!important}
      .jl-notify-head{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:15px;border-bottom:1px solid rgba(255,255,255,.09)}
      .jl-notify-head strong{font-size:.98rem}.jl-notify-head small{display:block;color:#91a4bd;margin-top:2px}
      .jl-notify-head-actions{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}
      .jl-notify-mini{border:1px solid rgba(255,255,255,.12);border-radius:9px;background:transparent;color:#dce6f4;padding:6px 8px;font:inherit;font-size:.72rem;font-weight:800;cursor:pointer}
      .jl-notify-list{overflow:auto;padding:8px}
      .jl-notify-empty{padding:28px 16px;text-align:center;color:#91a4bd}
      .jl-notify-item{display:grid;grid-template-columns:10px minmax(0,1fr);gap:10px;padding:12px;border-radius:12px;border:1px solid transparent;color:inherit;text-decoration:none;cursor:pointer}
      .jl-notify-item:hover{background:rgba(255,255,255,.045)}
      .jl-notify-item.unread{background:rgba(76,139,245,.09);border-color:rgba(76,139,245,.2)}
      .jl-notify-dot{width:8px;height:8px;margin-top:7px;border-radius:50%;background:#6f829d}.jl-notify-item.unread .jl-notify-dot{background:#f4bd42;box-shadow:0 0 0 4px rgba(244,189,66,.10)}
      .jl-notify-copy strong{display:block;color:#f4f7fb;font-size:.86rem}.jl-notify-copy p{margin:3px 0 0;color:#c7d3e2;font-size:.78rem;line-height:1.38}.jl-notify-copy time{display:block;margin-top:5px;color:#8195ae;font-size:.68rem}
      .jl-notify-foot{padding:10px 12px;border-top:1px solid rgba(255,255,255,.09);display:flex;align-items:center;justify-content:space-between;gap:10px;color:#91a4bd;font-size:.7rem}
      .jl-notify-device.enabled{border-color:rgba(53,201,133,.45);color:#8df1bb}
      @media(max-width:600px){.jl-notify-panel{position:fixed;left:10px;right:10px;top:68px;width:auto;max-height:calc(100dvh - 82px)}.jl-notify-button{width:38px;height:38px}.jl-notify-head{align-items:flex-start}.jl-notify-head-actions{max-width:150px}}
    `;
    document.head.appendChild(style);
  }

  function createUi() {
    if (ui.root?.isConnected) return true;
    const host = document.querySelector('.top-actions');
    if (!host) return false;

    injectStyle();
    const root = document.createElement('div');
    root.className = 'jl-notify-wrap hidden';
    root.innerHTML = `
      <button class="jl-notify-button" type="button" aria-label="Notificações" aria-expanded="false">
        <span aria-hidden="true">🔔</span>
        <span class="jl-notify-badge hidden">0</span>
      </button>
      <section class="jl-notify-panel hidden" role="dialog" aria-label="Notificações">
        <div class="jl-notify-head">
          <div><strong>Notificações</strong><small class="jl-notify-summary">Sem notificações novas</small></div>
          <div class="jl-notify-head-actions">
            <button class="jl-notify-mini" type="button" data-jl-notify-read>Marcar lidas</button>
            <button class="jl-notify-mini" type="button" data-jl-notify-clear>Limpar</button>
          </div>
        </div>
        <div class="jl-notify-list"></div>
        <div class="jl-notify-foot">
          <span>Jogos Lendários</span>
          <button class="jl-notify-mini jl-notify-device" type="button">Ativar no aparelho</button>
        </div>
      </section>
    `;

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
      if (open) render();
    });

    root.querySelector('[data-jl-notify-read]').addEventListener('click', () => markAllRead());
    root.querySelector('[data-jl-notify-clear]').addEventListener('click', () => clearAll());
    ui.deviceButton.addEventListener('click', requestDevicePermission);
    ui.list.addEventListener('click', (event) => {
      const item = event.target.closest('[data-jl-notify-id]');
      if (!item) return;
      markRead(item.dataset.jlNotifyId);
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
    ui.button?.setAttribute('aria-expanded', 'false');
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
    if (summary) summary.textContent = unread ? `${unread} não lida${unread === 1 ? '' : 's'}` : 'Sem notificações novas';

    ui.list.innerHTML = items.length ? items.map((item) => {
      const tag = item.href ? 'a' : 'div';
      const href = item.href ? ` href="${escapeHtml(item.href)}"` : '';
      return `<${tag}${href} class="jl-notify-item${item.read ? '' : ' unread'}" data-jl-notify-id="${escapeHtml(item.id)}">
        <span class="jl-notify-dot" aria-hidden="true"></span>
        <span class="jl-notify-copy"><strong>${escapeHtml(item.title || 'Notificação')}</strong><p>${escapeHtml(item.message || '')}</p><time>${escapeHtml(formatWhen(item.createdAt))}</time></span>
      </${tag}>`;
    }).join('') : '<div class="jl-notify-empty">Ainda não há notificações.</div>';

    updateDeviceButton();
  }

  function normalizeItem(input) {
    const now = new Date().toISOString();
    const id = String(input?.id || `notice:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`);
    return {
      id,
      title: String(input?.title || 'Notificação'),
      message: String(input?.message || ''),
      type: String(input?.type || 'info'),
      href: input?.href ? String(input.href) : '',
      createdAt: input?.createdAt || now,
      read: Boolean(input?.read)
    };
  }

  function push(input) {
    if (!token()) return false;
    const item = normalizeItem(input);
    const items = readItems();
    const existing = items.findIndex((entry) => entry.id === item.id);
    if (existing >= 0) {
      items[existing] = { ...items[existing], ...item, read: items[existing].read };
      writeItems(items);
      render();
      return false;
    }

    items.unshift(item);
    writeItems(items);
    render();
    maybeDeviceNotification(item);
    return true;
  }

  function markRead(id) {
    const items = readItems();
    let changed = false;
    for (const item of items) {
      if (item.id === id && !item.read) {
        item.read = true;
        changed = true;
      }
    }
    if (changed) writeItems(items);
    render();
  }

  function markAllRead() {
    const items = readItems().map((item) => ({ ...item, read: true }));
    writeItems(items);
    render();
  }

  function clearAll() {
    writeItems([]);
    render();
  }

  function updateDeviceButton(message = '') {
    if (!ui.deviceButton) return;
    if (!('Notification' in window)) {
      ui.deviceButton.textContent = 'Não suportado';
      ui.deviceButton.disabled = true;
      return;
    }
    const enabled = localStorage.getItem(DEVICE_KEY) === '1' && Notification.permission === 'granted';
    ui.deviceButton.disabled = false;
    ui.deviceButton.classList.toggle('enabled', enabled);
    ui.deviceButton.textContent = message || (enabled ? 'Avisos no aparelho: ligados' : 'Ativar no aparelho');
  }

  async function requestDevicePermission() {
    if (!('Notification' in window)) return updateDeviceButton('Não suportado');
    if (Notification.permission === 'denied') return updateDeviceButton('Bloqueado no navegador');
    try {
      const permission = await Notification.requestPermission();
      const enabled = permission === 'granted';
      localStorage.setItem(DEVICE_KEY, enabled ? '1' : '0');
      updateDeviceButton(enabled ? 'Avisos no aparelho: ligados' : 'Permissão não concedida');
    } catch {
      updateDeviceButton('Não foi possível ativar');
    }
  }

  function maybeDeviceNotification(item) {
    if (!('Notification' in window)) return;
    if (Notification.permission !== 'granted') return;
    if (localStorage.getItem(DEVICE_KEY) !== '1') return;
    if (document.visibilityState === 'visible' && document.hasFocus()) return;
    try {
      const n = new Notification(`Jogos Lendários · ${item.title}`, {
        body: item.message,
        tag: item.id,
        renotify: false
      });
      n.onclick = () => {
        window.focus();
        markRead(item.id);
        if (item.href) window.location.href = item.href;
        n.close();
      };
    } catch {}
  }

  function setActive(value = true) {
    active = Boolean(value);
    render();
  }

  function refresh() {
    render();
  }

  window.JLNotifications = Object.freeze({
    push,
    markRead,
    markAllRead,
    clearAll,
    setActive,
    refresh
  });

  const boot = () => {
    createUi();
    active = Boolean(token());
    render();
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();

  window.addEventListener('storage', (event) => {
    if (event.key === TOKEN_KEY || event.key?.startsWith(STORAGE_PREFIX) || event.key === DEVICE_KEY) render();
  });
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') render(); });
})();
