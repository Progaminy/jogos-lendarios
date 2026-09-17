(() => {
  'use strict';
  if (window.__JL_PUBLIC_CHALLENGES_V2__) return;
  window.__JL_PUBLIC_CHALLENGES_V2__ = true;

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  let busy = false;
  let timer = null;
  let lastSignature = '';

  const $ = (sel, root = document) => root.querySelector(sel);
  const escapeHtml = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const money = (v) => Number(v || 0).toLocaleString('pt-MZ', {minimumFractionDigits:2, maximumFractionDigits:2});

  async function rpc(name, args = {}) {
    if (!cfg.supabaseUrl || !cfg.supabaseKey) throw new Error('Configuração do Supabase ausente.');
    const res = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {apikey: cfg.supabaseKey, Authorization: `Bearer ${cfg.supabaseKey}`, 'Content-Type':'application/json', Accept:'application/json'},
      body: JSON.stringify(args)
    });
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    if (!res.ok) throw new Error(data?.message || data?.hint || data?.error || `Erro ${res.status}`);
    return data;
  }

  function toast(message, type='') {
    const el = $('#toast');
    if (!el) return;
    el.textContent = message;
    el.className = `toast show ${type}`;
    clearTimeout(toast.t);
    toast.t = setTimeout(() => { el.className = 'toast'; }, 4200);
  }

  function forceInitialTen() {
    for (const id of ['createBet','queueBet']) {
      const input = document.getElementById(id);
      if (!input) continue;
      input.min = '10';
      if (!input.dataset.jlInitialised) {
        input.value = '10';
        input.defaultValue = '10';
        input.dataset.jlInitialised = '1';
      }
    }
    const reentry = document.querySelector('input[name="reentry_amount"]');
    if (reentry) {
      reentry.min = '10';
      if (!reentry.dataset.jlInitialised) {
        reentry.value = '10';
        reentry.defaultValue = '10';
        reentry.dataset.jlInitialised = '1';
      }
    }
  }

  function injectStyles() {
    if ($('#jlChallengeV2Styles')) return;
    const s = document.createElement('style');
    s.id = 'jlChallengeV2Styles';
    s.textContent = `
      #globalChallengePanel{margin:14px 0 18px;padding:18px!important;border:1px solid rgba(244,181,31,.28)!important;background:linear-gradient(135deg,rgba(244,181,31,.09),rgba(15,24,38,.98))!important;box-shadow:0 14px 34px rgba(0,0,0,.22)}
      #globalChallengePanel.hidden{display:none!important}.gc-head{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:12px}.gc-head h2{margin:0}.gc-head p{margin:3px 0 0;color:#91a4bd}.gc-live{display:inline-flex;align-items:center;gap:7px;border:1px solid rgba(78,213,138,.28);background:rgba(78,213,138,.08);color:#8df1bb;border-radius:999px;padding:6px 9px;font-size:.7rem;font-weight:900}.gc-live::before{content:'';width:8px;height:8px;border-radius:50%;background:#4ed58a;box-shadow:0 0 0 4px rgba(78,213,138,.1)}
      #globalChallengeList{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:9px}.gc-card{display:grid;grid-template-columns:1fr auto;gap:12px;align-items:center;padding:13px;border:1px solid rgba(255,255,255,.08);border-radius:13px;background:rgba(255,255,255,.035)}.gc-card small{display:block;margin-top:4px;color:#91a4bd}.gc-tags{display:flex;flex-wrap:wrap;gap:5px;margin-top:7px}.gc-tags span{font-size:.65rem;font-weight:800;color:#ffda6a;border:1px solid rgba(244,181,31,.18);background:rgba(244,181,31,.07);border-radius:999px;padding:3px 6px}.gc-accept{border:0;border-radius:10px;background:#f4b51f;color:#181108;padding:10px 12px;font-weight:1000;cursor:pointer;white-space:nowrap}.gc-accept:hover{background:#ffda6a}.gc-empty{grid-column:1/-1;padding:12px;color:#91a4bd;text-align:center}.gc-note{margin-top:9px;color:#c8d2df;font-size:.75rem}.gc-flash{animation:gcFlash 1.15s ease 2}@keyframes gcFlash{50%{box-shadow:0 0 0 4px rgba(244,181,31,.22),0 18px 45px rgba(0,0,0,.3)}}
      #queueButton{background:#f4b51f!important;color:#171109!important;border-color:#f4b51f!important}.room-broadcast{background:rgba(244,181,31,.1)!important;color:#ffda6a!important;border-color:rgba(244,181,31,.34)!important}
      @media(max-width:760px){#globalChallengeList{grid-template-columns:1fr}.gc-card{grid-template-columns:1fr}.gc-accept{width:100%}.gc-head{align-items:flex-start}.gc-live{flex:none}}
    `;
    document.head.appendChild(s);
  }

  function ensurePanel() {
    let panel = $('#globalChallengePanel');
    if (panel) return panel;
    const main = $('main.shell');
    if (!main) return null;
    panel = document.createElement('section');
    panel.id = 'globalChallengePanel';
    panel.className = 'panel hidden';
    panel.innerHTML = `<div class="gc-head"><div><p class="eyebrow">CHAMADAS DE LUDO</p><h2>Alguém quer jogar agora</h2><p>Desafios públicos atualizados em tempo real.</p></div><span class="gc-live">AO VIVO</span></div><div id="globalChallengeList"><div class="gc-empty">Procurando desafios…</div></div><div class="gc-note">Cada anúncio fica ativo por 60 segundos. O anfitrião continua dentro da sala, no tabuleiro, enquanto espera.</div>`;
    const hero = $('.hero', main);
    if (hero) hero.after(panel); else main.prepend(panel);
    return panel;
  }

  function describe(c) {
    const mode = c.mode === 'partners' ? 'Parceiros 2×2' : 'Cada um por si';
    const place = c.play_location === 'presential' ? 'Presencial' : 'Online';
    const n = Number(c.dice_count || 1);
    return {mode, place, dice:`${n} ${n===1?'dado':'dados'}`};
  }

  function render(rows) {
    const panel = ensurePanel();
    const list = $('#globalChallengeList');
    if (!panel || !list) return;
    const good = Array.isArray(rows) ? rows : [];
    panel.classList.toggle('hidden', good.length === 0);
    if (!good.length) { list.innerHTML = '<div class="gc-empty">Nenhum desafio público ativo neste momento.</div>'; return; }
    const signature = good.map(x => `${x.room_id}:${x.joined_count}:${x.open_slots}`).join('|');
    if (lastSignature && signature !== lastSignature) panel.classList.add('gc-flash');
    setTimeout(() => panel.classList.remove('gc-flash'), 2400);
    lastSignature = signature;
    list.innerHTML = good.map(c => {
      const d = describe(c);
      return `<article class="gc-card"><div><strong>${escapeHtml(c.host_name)} · ${escapeHtml(c.host_code)}</strong><small>${escapeHtml(c.code)} · ${Number(c.joined_count||0)}/${Number(c.player_count||0)} jogadores · ${money(c.bet_amount)} MZN por jogador</small><div class="gc-tags"><span>${escapeHtml(d.mode)}</span><span>${escapeHtml(d.place)}</span><span>${escapeHtml(d.dice)}</span><span>${Number(c.open_slots||0)} vaga(s)</span></div></div><button class="gc-accept" type="button" data-accept-public-challenge="${escapeHtml(c.code)}">Aceitar e entrar</button></article>`;
    }).join('');
  }

  async function refresh() {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token) { ensurePanel()?.classList.add('hidden'); return; }
    try {
      const rows = await rpc('jl_ludo_public_challenges', {p_token: token});
      render(rows || []);
      const status = await rpc('jl_ludo_my_status', {p_token: token});
      if (status?.active_room_id) await ensureBroadcastButton(status.active_room_id);
    } catch (_) {}
  }

  async function ensureBroadcastButton(roomId) {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token || !roomId) return;
    try {
      const st = await rpc('jl_ludo_room_state', {p_token: token, p_room: roomId});
      const r = st?.room;
      if (!r || r.host_id !== st?.identity?.player_id || !r.is_public || !['waiting','negotiating'].includes(r.status)) return;
      const joined = (st.players||[]).filter(p => p.status !== 'left').length;
      if (joined >= Number(r.player_count||0)) return;
      const host = $('#ludoQuickBar .ludo-quick-actions') || $('.room-actions');
      if (!host || $('#broadcastEveryone', host)) return;
      const b = document.createElement('button');
      b.id = 'broadcastEveryone'; b.type = 'button'; b.className = 'room-broadcast'; b.textContent = '📣 Convidar todos';
      b.addEventListener('click', async () => {
        if (busy) return;
        busy = true; b.disabled = true;
        try { await rpc('jl_ludo_rebroadcast_challenge', {p_token: token, p_room: r.id}); toast('Convite enviado para todos por 60 segundos.','success'); await refresh(); }
        catch (e) { toast(e.message,'error'); }
        finally { busy = false; b.disabled = false; }
      });
      host.prepend(b);
    } catch (_) {}
  }

  function bindQueroJogar() {
    const form = $('#queueForm');
    const btn = $('#queueButton');
    if (!form || !btn || form.dataset.jlV2Bound) return;
    form.dataset.jlV2Bound = '1';
    btn.textContent = '📣 Quero jogar · convidar todos';
    const info = $('#queueStatus');
    if (info) { info.classList.remove('hidden'); info.innerHTML = 'Valor inicial <strong>10 MZN</strong>. Pode ajustar antes de lançar. Ao clicar, você entra na sala e o convite aparece para todos por 60 segundos.'; }
    form.addEventListener('submit', async (event) => {
      event.preventDefault(); event.stopImmediatePropagation();
      if (busy) return;
      const token = localStorage.getItem(TOKEN_KEY); if (!token) return;
      busy = true; btn.disabled = true; const old = btn.textContent; btn.textContent = 'Abrindo sala…';
      try {
        try { await rpc('jl_ludo_leave_queue', {p_token: token}); } catch (_) {}
        await rpc('jl_ludo_create_room', {p_token: token,p_player_count:Number($('#queuePlayers')?.value||4),p_bet_amount:Number($('#queueBet')?.value||10),p_mode:$('#queueMode')?.value||'solo',p_is_public:true,p_rules:{}});
        sessionStorage.setItem('jl_public_v2_created','1');
        location.reload();
      } catch (e) { toast(e.message,'error'); btn.textContent = old; busy = false; btn.disabled = false; }
    }, true);
  }

  function bindAccept() {
    document.addEventListener('click', async (event) => {
      const btn = event.target.closest('[data-accept-public-challenge]');
      if (!btn || busy) return;
      const token = localStorage.getItem(TOKEN_KEY); if (!token) return;
      busy = true; btn.disabled = true; const old = btn.textContent; btn.textContent = 'Entrando…';
      try {
        await rpc('jl_ludo_accept_public_challenge', {p_token: token, p_code: btn.dataset.acceptPublicChallenge});
        sessionStorage.setItem('jl_public_v2_joined','1');
        location.reload();
      } catch (e) { toast(e.message,'error'); btn.disabled = false; btn.textContent = old; busy = false; }
    });
  }

  function startupMessages() {
    if (sessionStorage.getItem('jl_public_v2_created')) { sessionStorage.removeItem('jl_public_v2_created'); setTimeout(()=>toast('Sua sala está aberta. O convite está visível para todos por 60 segundos.','success'),350); }
    if (sessionStorage.getItem('jl_public_v2_joined')) { sessionStorage.removeItem('jl_public_v2_joined'); setTimeout(()=>toast('Você entrou no desafio e já está no tabuleiro.','success'),350); }
  }

  function init() {
    injectStyles(); forceInitialTen(); ensurePanel(); bindQueroJogar(); bindAccept(); startupMessages(); refresh();
    clearInterval(timer); timer = setInterval(refresh, 2000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, {once:true}); else init();
})();
