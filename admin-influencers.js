(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_admin_token';
  const $ = (id) => document.getElementById(id);

  const state = {
    data: null,
    query: '',
    loading: false,
    timer: null
  };

  function token() {
    return window.JLSession?.getAdminToken?.() || sessionStorage.getItem(TOKEN_KEY) || '';
  }

  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/[&<>'"]/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
    }[c]));
  }

  function when(value) {
    if (!value) return '—';
    const d = new Date(value);
    return Number.isNaN(d.getTime()) ? '—' : d.toLocaleString('pt-MZ', { dateStyle: 'short', timeStyle: 'short' });
  }

  async function rpc(name, args = {}) {
    if (!cfg.supabaseUrl || !cfg.supabaseKey) throw new Error('Configuração do Supabase ausente.');
    const response = await fetch(cfg.supabaseUrl + '/rest/v1/rpc/' + name, {
      method: 'POST',
      headers: {
        apikey: cfg.supabaseKey,
        Authorization: 'Bearer ' + cfg.supabaseKey,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify(args)
    });
    const raw = await response.text();
    let data = null;
    try { data = raw ? JSON.parse(raw) : null; } catch { data = raw; }
    if (!response.ok) throw new Error((data && (data.message || data.error || data.hint)) || ('Erro ' + response.status));
    return data;
  }

  function injectStyle() {
    if ($('jlInfluencerAdminStyle')) return;
    const style = document.createElement('style');
    style.id = 'jlInfluencerAdminStyle';
    style.textContent = [
      '.influencer-admin-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin:14px 0}',
      '.influencer-admin-metric{padding:14px;border:1px solid rgba(255,255,255,.1);border-radius:13px;background:rgba(255,255,255,.035)}',
      '.influencer-admin-metric small{display:block;color:#91a4bd}.influencer-admin-metric strong{display:block;font-size:1.35rem;margin-top:4px}',
      '.influencer-form{display:grid;grid-template-columns:minmax(180px,1fr) minmax(180px,1fr) auto;gap:10px;align-items:end;margin:14px 0}',
      '.influencer-toolbar{display:flex;gap:10px;align-items:end;justify-content:space-between;flex-wrap:wrap;margin:14px 0}',
      '.influencer-toolbar .field{min-width:min(100%,420px);flex:1}',
      '.influencer-list{display:grid;gap:10px}',
      '.influencer-card{border:1px solid rgba(255,255,255,.1);border-radius:14px;background:rgba(255,255,255,.025);overflow:hidden}',
      '.influencer-main{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:12px;padding:14px}',
      '.influencer-title{display:flex;align-items:center;gap:8px;flex-wrap:wrap}.influencer-title strong{font-size:.98rem}',
      '.influencer-code{display:inline-flex;align-items:center;gap:6px;margin-top:7px}.influencer-code code{font-weight:900;letter-spacing:.05em;color:#f4bd42}',
      '.influencer-meta{margin-top:5px;color:#91a4bd;font-size:.78rem;line-height:1.45}',
      '.influencer-actions{display:flex;gap:6px;align-items:flex-start;flex-wrap:wrap;justify-content:flex-end}',
      '.influencer-registrations{border-top:1px solid rgba(255,255,255,.08);padding:0 14px 14px}',
      '.influencer-registrations summary{cursor:pointer;padding:12px 0;font-weight:850;color:#dce6f4}',
      '.influencer-referral-row{display:flex;justify-content:space-between;gap:12px;padding:10px 0;border-top:1px solid rgba(255,255,255,.06)}',
      '.influencer-referral-row:first-of-type{border-top:0}.influencer-referral-row small{display:block;color:#91a4bd;margin-top:3px}',
      '.influencer-status-active{color:#8df1bb}.influencer-status-off{color:#ff8994}',
      '.influencer-form-message{min-height:1.2em;margin:6px 0 0;color:#91a4bd}',
      '@media(max-width:760px){.influencer-admin-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.influencer-form{grid-template-columns:1fr}.influencer-main{grid-template-columns:1fr}.influencer-actions{justify-content:flex-start}.influencer-referral-row{display:block}}'
    ].join('');
    document.head.appendChild(style);
  }

  function createSection() {
    let section = $('adminInfluencersPanel');
    if (section) return section;

    injectStyle();
    section = document.createElement('section');
    section.id = 'adminInfluencersPanel';
    section.className = 'card admin-card';
    section.innerHTML = `
      <div class="section-head">
        <div>
          <p class="eyebrow">INFLUENCIADORES</p>
          <h2>Códigos de convite e cadastros</h2>
        </div>
        <button id="refreshInfluencers" class="button ghost small" type="button">Atualizar</button>
      </div>
      <p class="muted-text">Registe o influenciador, gere um código exclusivo e acompanhe todos os jogadores cadastrados por esse código.</p>

      <div class="influencer-admin-grid">
        <div class="influencer-admin-metric"><small>Influenciadores</small><strong id="influencerCount">0</strong></div>
        <div class="influencer-admin-metric"><small>Ativos</small><strong id="influencerActiveCount">0</strong></div>
        <div class="influencer-admin-metric"><small>Cadastros com código</small><strong id="influencerReferralCount">0</strong></div>
        <div class="influencer-admin-metric"><small>Cadastros sem código</small><strong id="influencerWithoutCodeCount">0</strong></div>
      </div>

      <form id="influencerCreateForm" class="influencer-form">
        <label class="field"><span>Nome do influenciador</span><input id="influencerName" maxlength="80" required placeholder="Nome"></label>
        <label class="field"><span>Telefone <small>(opcional)</small></span><input id="influencerPhone" inputmode="tel" maxlength="20" placeholder="Ex.: 84xxxxxxx"></label>
        <button id="influencerCreateButton" class="button primary" type="submit">Registar e gerar código</button>
      </form>
      <p id="influencerFormMessage" class="influencer-form-message"></p>

      <div class="influencer-toolbar">
        <label class="field"><span>Pesquisar</span><input id="influencerSearch" type="search" placeholder="Influenciador, código, jogador ou telefone"></label>
      </div>

      <div id="influencerList" class="influencer-list"><div class="empty">Carregando influenciadores…</div></div>
    `;

    const playersPanel = $('adminPlayersPanel');
    if (playersPanel?.parentNode) playersPanel.parentNode.insertBefore(section, playersPanel);
    else $('adminApp')?.appendChild(section);

    $('refreshInfluencers')?.addEventListener('click', () => load(false));
    $('influencerSearch')?.addEventListener('input', (event) => {
      state.query = event.target.value || '';
      render();
    });

    $('influencerCreateForm')?.addEventListener('submit', createInfluencer);
    $('influencerList')?.addEventListener('click', onListClick);
    return section;
  }

  function filteredInfluencers() {
    const rows = state.data?.influencers || [];
    const q = state.query.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((row) => {
      const registrations = row.registrations || [];
      return [row.name, row.phone, row.code].some((v) => String(v || '').toLowerCase().includes(q)) ||
        registrations.some((r) => [r.name, r.phone, r.code_used].some((v) => String(v || '').toLowerCase().includes(q)));
    });
  }

  function render() {
    createSection();
    const data = state.data || {};
    $('influencerCount').textContent = String(data.influencer_count || 0);
    $('influencerActiveCount').textContent = String(data.active_influencer_count || 0);
    $('influencerReferralCount').textContent = String(data.referred_players || 0);
    $('influencerWithoutCodeCount').textContent = String(data.without_invite_code || 0);

    const rows = filteredInfluencers();
    const list = $('influencerList');
    if (!list) return;
    if (!rows.length) {
      list.innerHTML = '<div class="empty">' + (state.query ? 'Nenhum resultado para a pesquisa.' : 'Nenhum influenciador registado.') + '</div>';
      return;
    }

    list.innerHTML = rows.map((row) => {
      const regs = Array.isArray(row.registrations) ? row.registrations : [];
      const statusClass = row.active ? 'influencer-status-active' : 'influencer-status-off';
      const status = row.active ? 'ATIVO' : 'INATIVO';
      const regHtml = regs.length ? regs.map((r) => `
        <div class="influencer-referral-row">
          <div>
            <strong>${escapeHtml(r.name)}</strong>
            <small>+${escapeHtml(r.phone)} · cadastrado ${escapeHtml(when(r.player_created_at))}</small>
          </div>
          <small>Código: ${escapeHtml(r.code_used || row.code)}</small>
        </div>
      `).join('') : '<div class="empty">Ainda não há cadastros com este código.</div>';

      return `
        <article class="influencer-card">
          <div class="influencer-main">
            <div>
              <div class="influencer-title">
                <strong>${escapeHtml(row.name)}</strong>
                <span class="${statusClass}">${status}</span>
                <span class="badge muted">${Number(row.referral_count || 0)} cadastro${Number(row.referral_count || 0) === 1 ? '' : 's'}</span>
              </div>
              <div class="influencer-code">
                <code>${escapeHtml(row.code)}</code>
                <button class="button ghost tiny" type="button" data-copy-code="${escapeHtml(row.code)}">Copiar</button>
              </div>
              <div class="influencer-meta">
                ${row.phone ? '+' + escapeHtml(row.phone) + ' · ' : ''}Registado em ${escapeHtml(when(row.created_at))}
              </div>
            </div>
            <div class="influencer-actions">
              <button class="button ${row.active ? 'danger' : 'success'} small" type="button" data-influencer-active="${escapeHtml(row.id)}" data-next-active="${row.active ? 'false' : 'true'}">
                ${row.active ? 'Desativar código' : 'Ativar código'}
              </button>
            </div>
          </div>
          <details class="influencer-registrations" ${state.query && regs.length ? 'open' : ''}>
            <summary>Ver cadastros (${regs.length})</summary>
            ${regHtml}
          </details>
        </article>
      `;
    }).join('');
  }

  async function copyCode(code) {
    try {
      if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(code);
      else {
        const area = document.createElement('textarea');
        area.value = code;
        area.style.position = 'fixed';
        area.style.opacity = '0';
        document.body.appendChild(area);
        area.select();
        document.execCommand('copy');
        area.remove();
      }
      const msg = $('influencerFormMessage');
      if (msg) {
        msg.textContent = 'Código copiado: ' + code;
        msg.style.color = '#8df1bb';
      }
    } catch {}
  }

  async function onListClick(event) {
    const copy = event.target.closest('[data-copy-code]');
    if (copy) {
      await copyCode(copy.dataset.copyCode || '');
      return;
    }

    const toggle = event.target.closest('[data-influencer-active]');
    if (!toggle) return;
    const next = toggle.dataset.nextActive === 'true';
    toggle.disabled = true;
    try {
      const result = await rpc('jl_admin_set_influencer_active', {
        p_token: token(),
        p_influencer_id: toggle.dataset.influencerActive,
        p_active: next
      });
      const msg = $('influencerFormMessage');
      if (msg) {
        msg.textContent = result?.message || 'Estado atualizado.';
        msg.style.color = '#8df1bb';
      }
      await load(true);
    } catch (error) {
      const msg = $('influencerFormMessage');
      if (msg) {
        msg.textContent = error.message;
        msg.style.color = '#ff8994';
      }
    } finally {
      toggle.disabled = false;
    }
  }

  async function createInfluencer(event) {
    event.preventDefault();
    const adminToken = token();
    if (!adminToken) return;
    const name = $('influencerName')?.value.trim() || '';
    const phone = $('influencerPhone')?.value.trim() || '';
    const button = $('influencerCreateButton');
    const msg = $('influencerFormMessage');
    if (button) button.disabled = true;
    if (msg) {
      msg.textContent = 'A registar e gerar código…';
      msg.style.color = '';
    }
    try {
      const result = await rpc('jl_admin_create_influencer', {
        p_token: adminToken,
        p_name: name,
        p_phone: phone || null
      });
      $('influencerCreateForm')?.reset();
      if (msg) {
        msg.textContent = (result?.message || 'Influenciador registado.') + ' Código: ' + (result?.influencer?.code || '');
        msg.style.color = '#8df1bb';
      }
      await load(true);
    } catch (error) {
      if (msg) {
        msg.textContent = error.message;
        msg.style.color = '#ff8994';
      }
    } finally {
      if (button) button.disabled = false;
    }
  }

  async function load(silent = true) {
    createSection();
    const adminToken = token();
    if (!adminToken || state.loading) return;
    state.loading = true;
    try {
      state.data = await rpc('jl_admin_influencers', { p_token: adminToken });
      render();
    } catch (error) {
      if (!silent) {
        const msg = $('influencerFormMessage');
        if (msg) {
          msg.textContent = error.message;
          msg.style.color = '#ff8994';
        }
      }
    } finally {
      state.loading = false;
    }
  }

  function boot() {
    createSection();
    if (token()) load(true);
    window.addEventListener('jl-admin-session-changed', (event) => {
      if (event.detail?.authenticated) load(true);
      else state.data = null;
    });
    state.timer = setInterval(() => {
      if (token() && document.visibilityState === 'visible') load(true);
    }, 15000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();