(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  let ui = null;
  let busy = false;

  function token() {
    return window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
  }

  function toast(message, type = '') {
    const el = $('toast');
    if (!el) return;
    el.textContent = message;
    el.className = `toast show ${type}`.trim();
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { el.className = 'toast'; }, 4200);
  }

  function esc(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
    }[c]));
  }

  function when(value) {
    if (!value) return '—';
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return '—';
    return d.toLocaleString('pt-MZ', { dateStyle: 'short', timeStyle: 'short' });
  }

  function deviceName(agent) {
    const ua = String(agent || '');
    const os = /Android/i.test(ua) ? 'Android'
      : /iPhone|iPad|iPod/i.test(ua) ? 'iPhone/iPad'
      : /Windows/i.test(ua) ? 'Windows'
      : /Macintosh|Mac OS/i.test(ua) ? 'Mac'
      : /Linux/i.test(ua) ? 'Linux'
      : 'Dispositivo';

    const browser = /Edg\//i.test(ua) ? 'Edge'
      : /OPR\//i.test(ua) ? 'Opera'
      : /Chrome\//i.test(ua) ? 'Chrome'
      : /Firefox\//i.test(ua) ? 'Firefox'
      : /Safari\//i.test(ua) ? 'Safari'
      : '';

    return browser ? `${os} · ${browser}` : os;
  }

  function injectStyle() {
    if ($('jlPlayerSessionsStyle')) return;
    const style = document.createElement('style');
    style.id = 'jlPlayerSessionsStyle';
    style.textContent = [
      '.jl-session-modal{position:fixed;inset:0;z-index:180;display:grid;place-items:center;padding:16px;background:rgba(1,6,14,.78)}',
      '.jl-session-modal.hidden{display:none!important}',
      '.jl-session-card{width:min(620px,100%);max-height:min(760px,88dvh);overflow:auto;border:1px solid rgba(255,255,255,.13);border-radius:18px;background:#0d1b2c;padding:18px;box-shadow:0 28px 80px rgba(0,0,0,.58)}',
      '.jl-session-head{display:flex;align-items:flex-start;justify-content:space-between;gap:12px}',
      '.jl-session-head h2{margin:3px 0 0}.jl-session-head p{margin:5px 0 0;color:#91a4bd;font-size:.82rem}',
      '.jl-session-close{border:0;background:transparent;color:inherit;font-size:1.5rem;cursor:pointer}',
      '.jl-session-list{display:grid;gap:10px;margin:16px 0}',
      '.jl-session-item{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:12px;align-items:center;padding:12px;border:1px solid rgba(255,255,255,.1);border-radius:13px;background:rgba(255,255,255,.035)}',
      '.jl-session-item.current{border-color:rgba(53,201,133,.38);background:rgba(53,201,133,.07)}',
      '.jl-session-item strong{display:block}.jl-session-item small{display:block;color:#91a4bd;margin-top:3px;line-height:1.35}',
      '.jl-session-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}',
      '.jl-session-empty{padding:20px;text-align:center;color:#91a4bd}',
      '@media(max-width:560px){.jl-session-item{grid-template-columns:1fr}.jl-session-actions .button{flex:1 1 45%}}'
    ].join('');
    document.head.appendChild(style);
  }

  function ensureUi() {
    if (ui) return ui;
    const actions = document.querySelector('.account-menu-actions');
    if (!actions) return null;

    injectStyle();

    let open = $('accountMenuSessions');
    if (!open) {
      open = document.createElement('button');
      open.id = 'accountMenuSessions';
      open.type = 'button';
      open.className = 'button ghost small';
      open.textContent = 'Sessões';
      const logout = $('accountMenuLogout');
      actions.insertBefore(open, logout || null);
    }

    const modal = document.createElement('div');
    modal.id = 'playerSessionsModal';
    modal.className = 'jl-session-modal hidden';
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', 'true');
    modal.setAttribute('aria-labelledby', 'playerSessionsTitle');
    modal.innerHTML = `
      <section class="jl-session-card">
        <div class="jl-session-head">
          <div>
            <small>SEGURANÇA DA CONTA</small>
            <h2 id="playerSessionsTitle">Sessões e dispositivos</h2>
            <p>Veja onde a sua conta está ligada e encerre acessos que não reconhece.</p>
          </div>
          <button class="jl-session-close" type="button" aria-label="Fechar">×</button>
        </div>
        <div class="jl-session-list"><div class="jl-session-empty">A carregar…</div></div>
        <div class="jl-session-actions">
          <button class="button secondary small" type="button" data-session-rotate>Renovar esta sessão</button>
          <button class="button ghost small" type="button" data-session-others>Encerrar outras</button>
          <button class="button danger small" type="button" data-session-all>Encerrar todas</button>
        </div>
      </section>`;
    document.body.appendChild(modal);

    ui = {
      open,
      modal,
      list: modal.querySelector('.jl-session-list'),
      close: modal.querySelector('.jl-session-close'),
      rotate: modal.querySelector('[data-session-rotate]'),
      others: modal.querySelector('[data-session-others]'),
      all: modal.querySelector('[data-session-all]')
    };

    ui.open.addEventListener('click', async (event) => {
      event.preventDefault();
      if (!token()) return;
      ui.modal.classList.remove('hidden');
      document.body.classList.add('modal-open');
      await refresh();
    });

    ui.close.addEventListener('click', close);
    ui.modal.addEventListener('click', (event) => {
      if (event.target === ui.modal) close();
    });

    ui.list.addEventListener('click', async (event) => {
      const button = event.target.closest('[data-session-revoke]');
      if (!button || busy) return;
      busy = true;
      button.disabled = true;
      try {
        await window.JLApi.rpc('jl_player_revoke_session', {
          p_token: token(),
          p_session_id: button.dataset.sessionRevoke
        });
        toast('Sessão encerrada.', 'success');
        await refresh();
      } catch (error) {
        toast(error.message, 'error');
      } finally {
        busy = false;
      }
    });

    ui.others.addEventListener('click', async () => {
      if (busy || !token()) return;
      busy = true;
      try {
        const result = await window.JLApi.rpc('jl_player_revoke_other_sessions', { p_token: token() });
        toast(`${Number(result?.revoked || 0)} outra(s) sessão(ões) encerrada(s).`, 'success');
        await refresh();
      } catch (error) {
        toast(error.message, 'error');
      } finally {
        busy = false;
      }
    });

    ui.rotate.addEventListener('click', async () => {
      if (busy || !token()) return;
      busy = true;
      try {
        const result = await window.JLApi.rpc('jl_rotate_player_session', { p_token: token() });
        if (!result?.token) throw new Error('Não foi possível renovar a sessão.');
        window.JLSession?.setPlayerToken?.(result.token);
        toast('Sessão renovada com um novo token.', 'success');
        setTimeout(() => window.location.reload(), 180);
      } catch (error) {
        busy = false;
        toast(error.message, 'error');
      }
    });

    ui.all.addEventListener('click', async () => {
      if (busy || !token()) return;
      if (!window.confirm('Encerrar todas as sessões desta conta, incluindo esta?')) return;
      busy = true;
      try {
        await window.JLApi.rpc('jl_player_revoke_all_sessions', { p_token: token() });
        window.JLSession?.setPlayerToken?.('');
        close();
        toast('Todas as sessões foram encerradas.', 'success');
        setTimeout(() => window.location.reload(), 180);
      } catch (error) {
        busy = false;
        toast(error.message, 'error');
      }
    });

    window.addEventListener('jl-player-session-changed', (event) => {
      if (!event.detail?.authenticated) close();
    });

    return ui;
  }

  async function refresh() {
    if (!ui || !token()) return;
    ui.list.innerHTML = '<div class="jl-session-empty">A carregar…</div>';
    try {
      const rows = await window.JLApi.rpc('jl_player_sessions', { p_token: token() });
      render(Array.isArray(rows) ? rows : []);
    } catch (error) {
      ui.list.innerHTML = `<div class="jl-session-empty">${esc(error.message)}</div>`;
    }
  }

  function render(rows) {
    if (!rows.length) {
      ui.list.innerHTML = '<div class="jl-session-empty">Nenhuma sessão ativa.</div>';
      return;
    }

    ui.list.innerHTML = rows.map((row) => {
      const current = Boolean(row.is_current);
      const action = current
        ? '<span class="badge">Esta sessão</span>'
        : `<button class="button danger small" type="button" data-session-revoke="${esc(row.session_id)}">Encerrar</button>`;

      return `
        <article class="jl-session-item${current ? ' current' : ''}">
          <div>
            <strong>${esc(deviceName(row.user_agent))}</strong>
            <small>Último uso: ${esc(when(row.last_seen_at))}</small>
            <small>Iniciada: ${esc(when(row.created_at))} · expira: ${esc(when(row.expires_at))}</small>
          </div>
          <div>${action}</div>
        </article>`;
    }).join('');
  }

  function close() {
    if (!ui) return;
    ui.modal.classList.add('hidden');
    document.body.classList.remove('modal-open');
  }

  function init() {
    ensureUi();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }
})();