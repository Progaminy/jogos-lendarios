(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_admin_token';
  const $ = (id) => document.getElementById(id);

  const token = () => localStorage.getItem(TOKEN_KEY) || '';

  const esc = (value) => String(value ?? '').replace(/[&<>'"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
  }[c]));

  function toast(message, type = '') {
    const el = $('toast');
    if (!el) return;
    el.textContent = message;
    el.className = `toast show ${type}`.trim();
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { el.className = 'toast'; }, 4200);
  }

  async function rpc(name, args = {}) {
    const response = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
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
    if (!response.ok) {
      throw new Error(payload?.message || payload?.error || payload?.hint || `Erro ${response.status}`);
    }
    return payload;
  }

  async function secureRpc(name, args = {}, retried = false) {
    try {
      return await rpc(name, args);
    } catch (error) {
      if (!retried && /REAUTH_REQUIRED/i.test(error.message || '') && typeof window.JLAdminReauthenticate === 'function') {
        const ok = await window.JLAdminReauthenticate();
        if (ok) return secureRpc(name, args, true);
      }
      throw error;
    }
  }

  function ensurePanel() {
    const app = $('adminApp');
    if (!app || $('adminSecurityPanel')) return;

    const section = document.createElement('section');
    section.id = 'adminSecurityPanel';
    section.className = 'card admin-card';
    section.innerHTML = `
      <details id="adminSecurityDetails">
        <summary style="cursor:pointer;font-weight:800">Segurança administrativa</summary>
        <div style="margin-top:16px">
          <div class="section-head">
            <div>
              <p class="eyebrow">AUTENTICAÇÃO</p>
              <h2>Identidade e acesso administrativo</h2>
              <p class="muted-text">Cada administrador tem identidade própria. Operações críticas pedem confirmação recente do código.</p>
            </div>
            <span id="adminIdentityBadge" class="badge muted">A verificar…</span>
          </div>

          <div class="row-actions" style="margin:12px 0 18px">
            <button id="adminChangeOwnCode" class="button ghost small" type="button">Alterar meu código</button>
            <button id="adminRefreshSecurity" class="button ghost small" type="button">Atualizar</button>
          </div>

          <div id="adminSuperArea" class="hidden">
            <div class="card" style="margin-bottom:14px">
              <p class="eyebrow">SUPER ADMINISTRADOR</p>
              <h3>Criar administrador</h3>
              <form id="adminCreateAccountForm" class="stack-form">
                <label class="field">
                  <span>Nome</span>
                  <input id="adminNewName" type="text" minlength="2" maxlength="80" required>
                </label>
                <label class="field">
                  <span>Função</span>
                  <select id="adminNewRole">
                    <option value="admin">Administrador</option>
                    <option value="super_admin">Super administrador</option>
                  </select>
                </label>
                <label class="field">
                  <span>Código de acesso</span>
                  <input id="adminNewCode" type="password" minlength="6" maxlength="64" autocomplete="new-password" required>
                </label>
                <button class="button primary" type="submit">Criar administrador</button>
              </form>
            </div>

            <div>
              <p class="eyebrow">ADMINISTRADORES</p>
              <div id="adminAccountsList" class="request-list">
                <div class="empty">A carregar administradores…</div>
              </div>
            </div>
          </div>
        </div>
      </details>`;

    app.prepend(section);

    $('adminRefreshSecurity')?.addEventListener('click', () => refresh(false));
    $('adminChangeOwnCode')?.addEventListener('click', changeOwnCode);
    $('adminCreateAccountForm')?.addEventListener('submit', createAccount);
    $('adminAccountsList')?.addEventListener('click', toggleAccount);
  }

  function renderAccounts(items, me) {
    const box = $('adminAccountsList');
    if (!box) return;
    if (!Array.isArray(items) || !items.length) {
      box.innerHTML = '<div class="empty">Nenhum administrador cadastrado.</div>';
      return;
    }

    box.innerHTML = items.map((item) => {
      const isMe = String(item.id) === String(me?.id);
      const role = item.role === 'super_admin' ? 'Super administrador' : 'Administrador';
      const state = item.active ? 'Ativo' : 'Desativado';
      const login = item.last_login_at
        ? new Date(item.last_login_at).toLocaleString('pt-MZ', { dateStyle: 'short', timeStyle: 'short' })
        : 'Nunca';

      return `<div class="request-row">
        <div>
          <strong>${esc(item.name)}${isMe ? ' · você' : ''}</strong><br>
          <small>${esc(role)} · ${esc(state)} · último acesso: ${esc(login)}</small>
        </div>
        <span class="badge ${item.active ? 'success' : 'muted'}">${esc(state)}</span>
        <div class="row-actions">
          <button
            class="button ${item.active ? 'danger' : 'success'} small"
            type="button"
            data-admin-toggle="${esc(item.id)}"
            data-next-active="${item.active ? 'false' : 'true'}"
            ${isMe && item.active ? 'disabled' : ''}
          >${item.active ? 'Desativar' : 'Reativar'}</button>
        </div>
      </div>`;
    }).join('');
  }

  async function refresh(silent = true) {
    if (!token()) return;
    ensurePanel();

    try {
      const info = await rpc('jl_admin_session_info', { p_token: token() });
      const badge = $('adminIdentityBadge');
      if (badge) {
        badge.textContent = `${info.name || 'Administrador'} · ${info.role === 'super_admin' ? 'SUPER' : 'ADMIN'}`;
        badge.className = 'badge success';
      }

      const superArea = $('adminSuperArea');
      if (info.role === 'super_admin') {
        superArea?.classList.remove('hidden');
        const items = await rpc('jl_admin_list_accounts', { p_token: token() });
        renderAccounts(items, info);
      } else {
        superArea?.classList.add('hidden');
      }
    } catch (error) {
      if (!silent) toast(error.message, 'error');
    }
  }

  async function changeOwnCode() {
    const current = window.prompt('Digite o código administrativo atual:');
    if (current === null) return;
    const next = window.prompt('Digite o novo código administrativo (mínimo 6 caracteres):');
    if (next === null) return;
    const confirm = window.prompt('Repita o novo código administrativo:');
    if (confirm === null) return;

    if (next !== confirm) {
      toast('Os novos códigos não coincidem.', 'error');
      return;
    }

    try {
      const result = await rpc('jl_admin_change_own_code', {
        p_token: token(),
        p_current_code: current,
        p_new_code: next
      });
      toast(result?.message || 'Código administrativo alterado.', 'success');
      await refresh(true);
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  async function createAccount(event) {
    event.preventDefault();
    const name = $('adminNewName')?.value.trim() || '';
    const role = $('adminNewRole')?.value || 'admin';
    const code = $('adminNewCode')?.value || '';

    try {
      const result = await secureRpc('jl_admin_create_account', {
        p_token: token(),
        p_display_name: name,
        p_role: role,
        p_code: code
      });
      event.currentTarget.reset();
      toast(`${result?.name || 'Administrador'} criado com sucesso.`, 'success');
      await refresh(true);
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  async function toggleAccount(event) {
    const button = event.target.closest('[data-admin-toggle]');
    if (!button) return;

    const active = button.dataset.nextActive === 'true';
    const verb = active ? 'reativar' : 'desativar';
    if (!window.confirm(`Deseja ${verb} este administrador?`)) return;

    try {
      await secureRpc('jl_admin_set_account_active', {
        p_token: token(),
        p_admin_id: button.dataset.adminToggle,
        p_active: active
      });
      toast(`Administrador ${active ? 'reativado' : 'desativado'}.`, 'success');
      await refresh(true);
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  function reset() {
    const badge = $('adminIdentityBadge');
    if (badge) {
      badge.textContent = 'Aguardando login';
      badge.className = 'badge muted';
    }
    $('adminSuperArea')?.classList.add('hidden');
  }

  function init() {
    ensurePanel();
    if (token()) refresh(true);
    else reset();
  }

  window.addEventListener('jl-admin-session-changed', (event) => {
    if (event.detail?.authenticated) setTimeout(() => refresh(true), 0);
    else reset();
  });

  window.addEventListener('storage', (event) => {
    if (event.key !== TOKEN_KEY) return;
    if (event.newValue) refresh(true);
    else reset();
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }
})();
