(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  let busy = false;
  let timer = null;

  const $ = (sel, root = document) => root.querySelector(sel);
  const escapeHtml = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const money = (v) => Number(v || 0).toLocaleString('pt-MZ', {minimumFractionDigits:2, maximumFractionDigits:2});

  async function rpc(name, args = {}) {
    if (!cfg.supabaseUrl || !cfg.supabaseKey) throw new Error('Configuração do Supabase ausente.');
    const res = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {
        apikey: cfg.supabaseKey,
        Authorization: `Bearer ${cfg.supabaseKey}`,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify(args)
    });
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    if (!res.ok) throw new Error(data?.message || data?.hint || data?.error || `Erro ${res.status}`);
    return data;
  }

  function toast(message, type = '') {
    const el = $('#toast');
    if (!el) return;
    el.textContent = message;
    el.className = `toast show ${type}`;
    clearTimeout(toast.t);
    toast.t = setTimeout(() => { el.className = 'toast'; }, 3500);
  }

  function injectStyles() {
    if ($('#publicChallengeStyles')) return;
    const style = document.createElement('style');
    style.id = 'publicChallengeStyles';
    style.textContent = `
      .public-challenges{padding:24px!important;position:relative;overflow:hidden}
      .public-challenges::before{content:'';position:absolute;inset:0 auto 0 0;width:4px;background:#f4b51f}
      .challenge-head{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:14px}
      .challenge-head h2{margin:0}.challenge-head p{margin:4px 0 0;color:#91a4bd}
      .challenge-live{display:inline-flex;align-items:center;gap:7px;padding:6px 9px;border-radius:999px;border:1px solid rgba(78,213,138,.25);background:rgba(78,213,138,.08);color:#8df1bb;font-size:.72rem;font-weight:900}
      .challenge-live::before{content:'';width:8px;height:8px;border-radius:50%;background:#4ed58a;box-shadow:0 0 0 5px rgba(78,213,138,.10)}
      .challenge-list{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
      .challenge-card{display:grid;grid-template-columns:1fr auto;align-items:center;gap:14px;padding:14px;border:1px solid rgba(255,255,255,.08);border-radius:14px;background:linear-gradient(145deg,rgba(255,255,255,.045),rgba(255,255,255,.018))}
      .challenge-card strong{font-size:.96rem}.challenge-card small{display:block;margin-top:4px;color:#91a4bd;line-height:1.45}.challenge-tags{display:flex;flex-wrap:wrap;gap:5px;margin-top:8px}.challenge-tags span{padding:4px 7px;border-radius:999px;background:rgba(244,181,31,.08);border:1px solid rgba(244,181,31,.16);color:#ffda6a;font-size:.66rem;font-weight:800}
      .challenge-accept{border:0;border-radius:10px;background:#f4b51f;color:#171109;padding:10px 13px;font-weight:1000;cursor:pointer;white-space:nowrap}.challenge-accept:hover{background:#ffda6a}
      .challenge-empty{grid-column:1/-1;padding:18px;border:1px dashed rgba(255,255,255,.10);border-radius:14px;text-align:center;color:#91a4bd}
      .broadcast-note{margin-top:10px;padding:10px 12px;border-radius:11px;background:rgba(244,181,31,.06);border:1px solid rgba(244,181,31,.16);color:#d8e0ea;font-size:.78rem}
      .rebroadcast-button{border:1px solid rgba(244,181,31,.35)!important;background:rgba(244,181,31,.10)!important;color:#ffda6a!important}
      @media(max-width:760px){.challenge-list{grid-template-columns:1fr}.challenge-card{grid-template-columns:1fr}.challenge-accept{width:100%}}
    `;
    document.head.appendChild(style);
  }

  function ensureChallengePanel() {
    const lobby = $('#lobby');
    if (!lobby || $('#publicChallengesPanel')) return;
    const panel = document.createElement('section');
    panel.id = 'publicChallengesPanel';
    panel.className = 'panel full-span public-challenges';
    panel.innerHTML = `
      <div class="challenge-head">
        <div><p class="eyebrow">QUERO JOGAR · AO VIVO</p><h2>Jogadores procurando partida</h2><p>Um clique em “Quero jogar” anuncia a partida para todos durante 60 segundos.</p></div>
        <span class="challenge-live">AO VIVO</span>
      </div>
      <div id="publicChallengeList" class="challenge-list"><div class="challenge-empty">Procurando desafios…</div></div>
      <div class="broadcast-note"><strong>Como funciona:</strong> quem lança o desafio entra imediatamente na própria sala e fica no tabuleiro. Os outros jogadores veem o pedido aqui e podem entrar com um toque.</div>`;
    lobby.prepend(panel);
  }

  function describeMode(c) {
    const mode = c.mode === 'partners' ? 'Parceiros 2×2' : 'Cada um por si';
    const place = c.play_location === 'presential' ? 'Presencial' : 'Online';
    const dice = Number(c.dice_count || 1);
    return { mode, place, dice: `${dice} ${dice === 1 ? 'dado' : 'dados'}` };
  }

  function renderChallenges(rows) {
    ensureChallengePanel();
    const list = $('#publicChallengeList');
    if (!list) return;
    if (!Array.isArray(rows) || !rows.length) {
      list.innerHTML = '<div class="challenge-empty">Nenhum desafio público neste momento. Clique em <strong>Quero jogar</strong> para lançar o primeiro.</div>';
      return;
    }
    list.innerHTML = rows.map(c => {
      const d = describeMode(c);
      return `<article class="challenge-card">
        <div>
          <strong>${escapeHtml(c.host_name)} · ${escapeHtml(c.host_code)}</strong>
          <small>${escapeHtml(c.code)} · ${Number(c.joined_count || 0)}/${Number(c.player_count || 0)} jogadores · ${money(c.bet_amount)} MZN por jogador</small>
          <div class="challenge-tags"><span>${escapeHtml(d.mode)}</span><span>${escapeHtml(d.place)}</span><span>${escapeHtml(d.dice)}</span><span>${Number(c.open_slots || 0)} vaga(s)</span></div>
        </div>
        <button class="challenge-accept" type="button" data-accept-public-challenge="${escapeHtml(c.code)}">Aceitar e entrar</button>
      </article>`;
    }).join('');
  }

  async function refreshChallenges() {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token) return;
    try {
      const status = await rpc('jl_ludo_my_status', { p_token: token });
      if (status?.active_room_id) {
        await ensureRebroadcast(status.active_room_id);
        return;
      }
      const rows = await rpc('jl_ludo_public_challenges', { p_token: token });
      renderChallenges(rows || []);
    } catch (_) {}
  }

  async function ensureRebroadcast(roomId) {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token || !roomId) return;
    try {
      const state = await rpc('jl_ludo_room_state', { p_token: token, p_room: roomId });
      const room = state?.room;
      if (!room || room.host_id !== state?.identity?.player_id || !room.is_public || !['waiting','negotiating'].includes(room.status)) return;
      const joined = (state.players || []).filter(p => p.status !== 'left').length;
      if (joined >= Number(room.player_count || 0)) return;
      const quick = $('#ludoQuickBar .ludo-quick-actions');
      if (!quick || $('#rebroadcastChallenge', quick)) return;
      const btn = document.createElement('button');
      btn.id = 'rebroadcastChallenge';
      btn.type = 'button';
      btn.className = 'rebroadcast-button';
      btn.textContent = '📣 Convidar todos';
      btn.addEventListener('click', async () => {
        if (busy) return;
        busy = true; btn.disabled = true;
        try {
          await rpc('jl_ludo_rebroadcast_challenge', { p_token: token, p_room: room.id });
          toast('Desafio relançado para todos por 60 segundos.', 'success');
        } catch (e) { toast(e.message, 'error'); }
        finally { busy = false; btn.disabled = false; }
      });
      quick.prepend(btn);
    } catch (_) {}
  }

  function overrideQueroJogar() {
    const form = $('#queueForm');
    const button = $('#queueButton');
    if (!form || !button || form.dataset.publicChallengeBound === '1') return;
    form.dataset.publicChallengeBound = '1';
    button.textContent = '📣 Quero jogar · anunciar para todos';

    const oldStatus = $('#queueStatus');
    if (oldStatus) {
      oldStatus.classList.remove('hidden');
      oldStatus.innerHTML = 'Ao clicar, você <strong>entra imediatamente numa sala</strong> e o desafio fica visível para todos os jogadores durante 60 segundos.';
    }

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      event.stopImmediatePropagation();
      if (busy) return;
      const token = localStorage.getItem(TOKEN_KEY);
      if (!token) return;

      busy = true;
      button.disabled = true;
      const original = button.textContent;
      button.textContent = 'Abrindo sua sala…';
      try {
        if (button.dataset.queued) {
          await rpc('jl_ludo_leave_queue', { p_token: token });
          delete button.dataset.queued;
        } else {
          try { await rpc('jl_ludo_leave_queue', { p_token: token }); } catch (_) {}
          await rpc('jl_ludo_create_room', {
            p_token: token,
            p_player_count: Number($('#queuePlayers')?.value || 4),
            p_bet_amount: Number($('#queueBet')?.value || 10),
            p_mode: $('#queueMode')?.value || 'solo',
            p_is_public: true,
            p_rules: {}
          });
          sessionStorage.setItem('jl_public_challenge_created', '1');
          location.reload();
          return;
        }
        location.reload();
      } catch (e) {
        toast(e.message, 'error');
        button.textContent = original;
      } finally {
        busy = false;
        button.disabled = false;
      }
    }, true);
  }

  function bindChallengeAccept() {
    document.addEventListener('click', async (event) => {
      const btn = event.target.closest('[data-accept-public-challenge]');
      if (!btn || busy) return;
      const token = localStorage.getItem(TOKEN_KEY);
      if (!token) return;
      busy = true; btn.disabled = true; const old = btn.textContent; btn.textContent = 'Entrando…';
      try {
        await rpc('jl_ludo_join_public_room', { p_token: token, p_code: btn.dataset.acceptPublicChallenge });
        sessionStorage.setItem('jl_public_challenge_joined', '1');
        location.reload();
      } catch (e) {
        toast(e.message, 'error');
        btn.disabled = false; btn.textContent = old; busy = false;
      }
    });
  }

  function afterReloadMessage() {
    if (sessionStorage.getItem('jl_public_challenge_created')) {
      sessionStorage.removeItem('jl_public_challenge_created');
      setTimeout(() => toast('Sua sala está aberta. O desafio foi enviado para todos por 60 segundos.', 'success'), 500);
    }
    if (sessionStorage.getItem('jl_public_challenge_joined')) {
      sessionStorage.removeItem('jl_public_challenge_joined');
      setTimeout(() => toast('Você entrou no desafio. Já está na sala e no tabuleiro.', 'success'), 500);
    }
  }

  function init() {
    injectStyles();
    ensureChallengePanel();
    overrideQueroJogar();
    bindChallengeAccept();
    afterReloadMessage();
    refreshChallenges();
    clearInterval(timer);
    timer = setInterval(refreshChallenges, 4000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, {once:true});
  else init();
})();
