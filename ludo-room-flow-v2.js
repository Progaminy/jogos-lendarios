(() => {
  'use strict';
  if (window.__JL_LUDO_ROOM_FLOW_V2__) return;
  window.__JL_LUDO_ROOM_FLOW_V2__ = true;

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const money = (v) => Number(v || 0).toLocaleString('pt-MZ', {minimumFractionDigits:0, maximumFractionDigits:2});

  let roomState = null;
  let inviteState = null;
  let timer = null;
  let busy = false;

  async function rpc(name, args = {}) {
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
    const raw = await res.text();
    let data = null;
    try { data = raw ? JSON.parse(raw) : null; } catch { data = raw; }
    if (!res.ok) throw new Error(data?.message || data?.hint || data?.error || `Erro ${res.status}`);
    return data;
  }

  function toast(message, type='') {
    const el = $('#toast');
    if (!el) return;
    el.textContent = message;
    el.className = `toast show ${type}`.trim();
    clearTimeout(toast.t);
    toast.t = setTimeout(() => { el.className = 'toast'; }, 4200);
  }

  function injectStyles() {
    if ($('#jlRoomFlowStyles')) return;
    const s = document.createElement('style');
    s.id = 'jlRoomFlowStyles';
    s.textContent = `
      #roomFlowPanel{margin:0 0 14px;padding:14px;border-radius:16px;border:1px solid rgba(244,181,31,.28);background:linear-gradient(145deg,rgba(244,181,31,.10),rgba(13,20,32,.96));box-shadow:0 12px 28px rgba(0,0,0,.16)}
      .rf-head{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:11px}.rf-head strong{font-size:1rem}.rf-room-status{padding:5px 8px;border-radius:999px;background:rgba(255,255,255,.055);border:1px solid rgba(255,255,255,.09);color:#c7d2e1;font-size:.68rem;font-weight:900;text-transform:uppercase;letter-spacing:.06em}
      .rf-steps{display:grid;grid-template-columns:repeat(4,1fr);gap:7px;margin-bottom:12px}.rf-step{position:relative;display:flex;align-items:center;gap:7px;padding:8px;border-radius:11px;background:rgba(255,255,255,.035);border:1px solid rgba(255,255,255,.06);color:#8191a7;min-width:0}.rf-step b{display:grid;place-items:center;flex:0 0 24px;height:24px;border-radius:50%;background:#202b3c;color:#9eacbd;font-size:.72rem}.rf-step span{font-size:.7rem;font-weight:900;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.rf-step.done{color:#9decc1;border-color:rgba(78,213,138,.18);background:rgba(78,213,138,.055)}.rf-step.done b{background:#2fb875;color:#07180f}.rf-step.active{color:#ffdc72;border-color:rgba(244,181,31,.32);background:rgba(244,181,31,.08)}.rf-step.active b{background:#f4b51f;color:#171109;box-shadow:0 0 0 4px rgba(244,181,31,.09)}
      .rf-action{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:12px;align-items:center;padding:13px;border-radius:13px;background:#101a29;border:1px solid rgba(255,255,255,.07)}.rf-copy h3{margin:0 0 4px;font-size:1.05rem}.rf-copy p{margin:0;color:#9aabc0;font-size:.8rem;line-height:1.45}.rf-actions{display:flex;gap:7px;flex-wrap:wrap;justify-content:flex-end}.rf-btn{border:1px solid rgba(255,255,255,.12);border-radius:10px;background:#1b283b;color:#edf3fb;padding:10px 12px;font-weight:900;cursor:pointer}.rf-btn.primary{background:#f4b51f;color:#171109;border-color:#f4b51f;min-width:180px}.rf-btn.success{background:#35c37d;color:#08170f;border-color:#35c37d}.rf-btn:disabled{opacity:.55;cursor:wait}.rf-waiting{display:inline-flex;align-items:center;gap:7px}.rf-waiting::before{content:'';width:8px;height:8px;border-radius:50%;background:#f4b51f;box-shadow:0 0 0 5px rgba(244,181,31,.08);animation:rfPulse 1.1s infinite}@keyframes rfPulse{50%{opacity:.35}}
      .rf-invites{margin-top:11px;padding-top:11px;border-top:1px solid rgba(255,255,255,.07)}.rf-invite-head{display:flex;align-items:center;justify-content:space-between;gap:9px;margin-bottom:8px}.rf-invite-head strong{font-size:.84rem}.rf-invite-head .rf-small-actions{display:flex;gap:6px;flex-wrap:wrap}.rf-mini{border:1px solid rgba(255,255,255,.10);border-radius:8px;background:rgba(255,255,255,.035);color:#cbd5e1;padding:6px 8px;font-size:.68rem;font-weight:850;cursor:pointer}.rf-mini.gold{border-color:rgba(244,181,31,.30);background:rgba(244,181,31,.08);color:#ffdb6e}.rf-broadcast{display:flex;align-items:center;justify-content:space-between;gap:9px;margin-bottom:8px;padding:8px 10px;border-radius:10px;background:rgba(244,181,31,.055);border:1px solid rgba(244,181,31,.13);font-size:.72rem;color:#cad4df}.rf-broadcast strong{color:#ffdb6e}.rf-invite-list{display:grid;gap:6px;max-height:230px;overflow:auto}.rf-invite-item{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;align-items:center;padding:8px 10px;border-radius:10px;background:rgba(255,255,255,.025);border:1px solid rgba(255,255,255,.055)}.rf-invite-item strong{font-size:.78rem}.rf-invite-item small{display:block;margin-top:2px;color:#8494aa}.rf-status{font-size:.66rem;font-weight:900;padding:4px 7px;border-radius:999px;white-space:nowrap}.rf-status.pending{color:#ffdc72;background:rgba(244,181,31,.10)}.rf-status.accepted{color:#9decc1;background:rgba(78,213,138,.10)}.rf-status.problem{color:#ffc47b;background:rgba(255,149,64,.11)}.rf-status.declined,.rf-status.expired,.rf-status.cancelled{color:#a9b4c4;background:rgba(255,255,255,.055)}.rf-empty{padding:8px 0;color:#77879c;font-size:.72rem}
      .rf-recovery{margin:10px 0;padding:12px;border-radius:12px;border:1px solid rgba(255,177,64,.32);background:rgba(255,177,64,.08);display:flex;align-items:center;justify-content:space-between;gap:10px}.rf-recovery strong{display:block}.rf-recovery small{color:#b7c1cf}.rf-recovery button{border:0;border-radius:9px;background:#f4b51f;color:#171109;padding:9px 11px;font-weight:900;cursor:pointer}
      body.ludo-room-active #gamePanel.hidden #dice{display:grid!important;opacity:.62!important;filter:saturate(.65)}body.ludo-room-active #gamePanel.hidden #turnTitle{font-size:1.06rem!important}body.ludo-room-active #gamePanel.hidden #turnTitle::after{content:none!important}body.ludo-room-active #gamePanel.hidden #moveHint{display:block!important}
      .rf-dice-row{display:flex;gap:6px;flex-wrap:wrap;margin-top:6px}.rf-die{display:grid;place-items:center;min-width:34px;height:34px;padding:0 8px;border-radius:9px;background:#f6f7f9;color:#111820;font-size:1rem;font-weight:1000;border:2px solid rgba(0,0,0,.12)}.rf-die.current{outline:3px solid #f4b51f;outline-offset:2px}
      @media(max-width:760px){.rf-steps{grid-template-columns:1fr 1fr}.rf-action{grid-template-columns:1fr}.rf-actions{justify-content:stretch}.rf-btn{flex:1}.rf-btn.primary{min-width:0}.rf-head{align-items:flex-start}.rf-invite-head{align-items:flex-start;flex-direction:column}.rf-small-actions{width:100%}.rf-mini{flex:1}.rf-broadcast{align-items:flex-start;flex-direction:column}}
    `;
    document.head.appendChild(s);
  }

  function ensurePanel() {
    const boardPanel = $('#gamePanel .board-panel');
    if (!boardPanel) return null;
    let panel = $('#roomFlowPanel', boardPanel);
    if (panel) return panel;
    panel = document.createElement('section');
    panel.id = 'roomFlowPanel';
    panel.innerHTML = `
      <div class="rf-head"><div><strong>Preparação da partida</strong><div id="rfIdentity" style="color:#8596aa;font-size:.7rem;margin-top:2px"></div></div><span id="rfRoomStatus" class="rf-room-status">SALA</span></div>
      <div id="rfSteps" class="rf-steps"></div>
      <div id="rfAction" class="rf-action"></div>
      <div class="rf-invites">
        <div class="rf-invite-head"><strong>Convites desta sala <span id="rfInviteCount" style="color:#7f90a7"></span></strong><div class="rf-small-actions"><button class="rf-mini" type="button" data-rf-action="invite">+ Convidar jogador</button><button class="rf-mini gold" type="button" data-rf-action="broadcast">📣 Convidar todos</button></div></div>
        <div id="rfBroadcast" class="rf-broadcast"></div>
        <div id="rfInviteList" class="rf-invite-list"></div>
      </div>`;
    const quick = $('#ludoQuickBar', boardPanel);
    if (quick?.nextSibling) boardPanel.insertBefore(panel, quick.nextSibling);
    else boardPanel.prepend(panel);
    return panel;
  }

  function statusName(status) {
    return ({waiting:'Aguardando jogadores',negotiating:'Confirmando regras',funding:'Confirmando apostas',playing:'Em jogo',finished:'Terminada',cancelled:'Cancelada'})[status] || status || 'Sala';
  }

  function stepIndex(r) {
    if (r.status === 'waiting') return 0;
    if (r.status === 'negotiating') return 1;
    if (r.status === 'funding') return 2;
    return 3;
  }

  function renderSteps(st) {
    const root = $('#rfSteps');
    if (!root) return;
    const r = st.room;
    const current = stepIndex(r);
    const labels = ['Jogadores','Regras','Aposta','Jogar'];
    root.innerHTML = labels.map((label, i) => `<div class="rf-step ${i < current ? 'done' : i === current ? 'active' : ''}"><b>${i < current ? '✓' : i + 1}</b><span>${label}</span></div>`).join('');
  }

  function waitingNames(players, predicate) {
    return players.filter(predicate).map(p => p.code || p.name || 'jogador').join(', ');
  }

  function actionButton(label, action, cls='primary') {
    return `<button type="button" class="rf-btn ${cls}" data-rf-action="${action}">${label}</button>`;
  }

  function renderAction(st) {
    const root = $('#rfAction');
    if (!root) return;
    const r = st.room;
    const players = (st.players || []).filter(p => p.status !== 'left');
    const joined = players.length;
    const total = Number(r.player_count || 0);
    const full = joined === total;
    const me = st.identity?.player_id;
    const mine = players.find(p => p.player_id === me);
    const accepted = players.filter(p => p.accepted_rules_version === r.rules_version).length;
    const paid = players.filter(p => p.stake_paid).length;
    const acceptedMine = mine?.accepted_rules_version === r.rules_version;
    const isHost = r.host_id === me;
    let title = '';
    let text = '';
    let actions = '';

    if (r.status === 'waiting' || !full) {
      const missing = Math.max(0, total - joined);
      title = missing ? `Falta ${missing} jogador${missing === 1 ? '' : 'es'} para completar a sala` : 'Sala completa';
      text = isHost ? 'Você já está dentro da sala. Convide jogadores e continue vendo o tabuleiro enquanto espera.' : 'Você já está dentro da sala. O anfitrião está completando as vagas.';
      actions = isHost ? `${actionButton('+ Convidar jogador','invite')}${actionButton('📣 Convidar todos','broadcast','')}` : '<span class="rf-waiting">Aguardando completar a sala</span>';
    } else if (r.status === 'negotiating') {
      if (!acceptedMine) {
        title = 'As regras estão prontas para a sua confirmação';
        text = `Confira as regras abaixo. Ao aceitar, você avança para a confirmação da aposta de ${money(r.bet_amount)} MZN.`;
        actions = `${actionButton('✓ Aceitar regras e continuar','accept-rules','success')}${actionButton('Ver regras','rules','')}`;
      } else if (accepted < joined) {
        const who = waitingNames(players, p => p.accepted_rules_version !== r.rules_version);
        title = 'Você já aceitou as regras';
        text = `Aguardando ${who || 'os outros jogadores'} confirmar. Assim que todos aceitarem, a sala passa automaticamente para a aposta.`;
        actions = `${actionButton('Ver regras','rules','')}<span class="rf-waiting">${accepted}/${joined} aceitaram</span>`;
      } else {
        title = 'Todos aceitaram as regras';
        text = 'A sala está avançando automaticamente para a confirmação das apostas.';
        actions = '<span class="rf-waiting">Preparando aposta…</span>';
      }
    } else if (r.status === 'funding') {
      if (!mine?.stake_paid) {
        title = 'Último passo antes do primeiro dado';
        text = `Confirme a sua aposta de ${money(r.bet_amount)} MZN. O valor só é reservado agora, depois de todos terem aceitado as regras.`;
        actions = actionButton(`Confirmar aposta · ${money(r.bet_amount)} MZN`,'fund','success');
      } else if (paid < joined) {
        const who = waitingNames(players, p => !p.stake_paid);
        title = 'A sua aposta está confirmada ✓';
        text = `Aguardando ${who || 'os outros jogadores'} confirmar. Quando o último confirmar, o jogo começa automaticamente.`;
        actions = `<span class="rf-waiting">${paid}/${joined} apostas confirmadas</span>`;
      } else {
        title = 'Todos confirmaram a aposta';
        text = 'Iniciando a partida e escolhendo o primeiro jogador…';
        actions = '<span class="rf-waiting">Abrindo o jogo…</span>';
      }
    } else if (r.status === 'playing') {
      const current = players.find(p => p.player_id === r.current_player_id);
      const myTurn = r.current_player_id === me;
      if (myTurn && r.turn_phase === 'roll') {
        const diceCount = Number(r.rules?.dice_count || 1);
        title = 'É a sua vez';
        text = diceCount > 1 ? `Lance os ${diceCount} dados para começar a sua jogada.` : 'Lance o dado para começar a sua jogada.';
        actions = actionButton(diceCount > 1 ? `🎲 Lançar ${diceCount} dados` : '🎲 Lançar dado','roll','success');
      } else if (myTurn && r.turn_phase === 'move') {
        title = 'Agora mova uma peça';
        text = 'As peças válidas estão destacadas no tabuleiro. Escolha uma delas antes do tempo terminar.';
        actions = '<span class="rf-waiting">Escolha uma peça destacada</span>';
      } else {
        title = `Vez de ${current?.code || current?.name || 'outro jogador'}`;
        text = 'O dado e os movimentos aparecem no mesmo tabuleiro para todos em tempo real.';
        actions = '<span class="rf-waiting">Acompanhe a jogada</span>';
      }
    } else if (r.status === 'finished') {
      title = 'Partida terminada';
      text = 'O resultado e os pagamentos estão registrados abaixo.';
      actions = '';
    } else {
      title = statusName(r.status);
      text = 'A sala está atualizando.';
      actions = '<span class="rf-waiting">Atualizando…</span>';
    }

    root.innerHTML = `<div class="rf-copy"><h3>${esc(title)}</h3><p>${esc(text)}</p>${renderDiceValues(r)}</div><div class="rf-actions">${actions}</div>`;

    const turnTitle = $('#turnTitle');
    const moveHint = $('#moveHint');
    const die = $('#dice');
    if (!['playing','finished'].includes(r.status)) {
      if (turnTitle) turnTitle.textContent = title;
      if (moveHint) moveHint.textContent = text;
      if (die) die.textContent = '🎲';
    }
  }

  function renderDiceValues(r) {
    if (r.status !== 'playing') return '';
    const values = Array.isArray(r.dice_values) ? r.dice_values : [];
    if (!values.length) return '';
    const pos = Number(r.dice_position || 0);
    return `<div class="rf-dice-row">${values.map((v,i) => `<span class="rf-die ${i === pos ? 'current' : ''}">${Number(v)}</span>`).join('')}</div>`;
  }

  function inviteStatus(item) {
    if (item.status === 'accepted' && item.joined) return {label:'Entrou na sala ✓',cls:'accepted'};
    if (item.status === 'accepted' && !item.joined) return {label:'Aceitou · entrada pendente',cls:'problem'};
    if (item.status === 'pending') return {label:'Aguardando resposta',cls:'pending'};
    if (item.status === 'declined') return {label:'Recusou',cls:'declined'};
    if (item.status === 'expired') return {label:'Expirou',cls:'expired'};
    return {label:item.status || '—',cls:'cancelled'};
  }

  function secondsLeft(value) {
    if (!value) return 0;
    return Math.max(0, Math.ceil((new Date(value).getTime() - Date.now()) / 1000));
  }

  function renderInvites(st, data) {
    const list = $('#rfInviteList');
    const count = $('#rfInviteCount');
    const broadcast = $('#rfBroadcast');
    if (!list || !broadcast) return;
    const items = Array.isArray(data?.items) ? data.items : [];
    if (count) count.textContent = `(${items.length})`;
    const publicLeft = secondsLeft(data?.public_challenge_expires_at);
    broadcast.innerHTML = st.room.is_public
      ? `<span>📣 Convite para todos: <strong>${publicLeft > 0 ? `ativo por ${publicLeft}s` : 'não está ativo'}</strong></span><span>${publicLeft > 0 ? 'Outros jogadores conseguem ver e entrar.' : 'Use “Convidar todos” para anunciar a sala.'}</span>`
      : `<span>🔒 Sala privada</span><span>Convide jogadores individualmente ou copie o código da sala.</span>`;

    if (!items.length) {
      list.innerHTML = '<div class="rf-empty">Nenhum convite individual enviado nesta sala.</div>';
      return;
    }
    list.innerHTML = items.map(item => {
      const s = inviteStatus(item);
      const pendingLeft = item.status === 'pending' ? secondsLeft(item.expires_at) : 0;
      return `<div class="rf-invite-item"><div><strong>${esc(item.name)} · ${esc(item.code)}</strong><small>${item.status === 'pending' ? `responde em até ${pendingLeft}s` : 'convite registrado'}</small></div><span class="rf-status ${s.cls}">${esc(s.label)}</span></div>`;
    }).join('');
  }

  function render(st, invites) {
    if (!st?.room) return;
    ensurePanel();
    $('#rfRoomStatus').textContent = statusName(st.room.status);
    const mine = (st.players || []).find(p => p.player_id === st.identity?.player_id);
    const id = $('#rfIdentity');
    if (id) id.textContent = mine ? `${mine.code || ''} · ${mine.color || ''}${mine.team ? ` · equipa ${mine.team}` : ''}` : (st.identity?.code || '');
    renderSteps(st);
    renderAction(st);
    renderInvites(st, invites);
  }

  function ensureRecovery(invites) {
    const list = $('#inviteList');
    if (!list) return;
    const recoverable = (invites || []).filter(i => i.recoverable || i.status === 'accepted');
    let box = $('#rfRecoveryBox');
    if (!recoverable.length) { box?.remove(); return; }
    const i = recoverable[0];
    if (!box) {
      box = document.createElement('div');
      box.id = 'rfRecoveryBox';
      list.prepend(box);
    }
    box.className = 'rf-recovery';
    box.innerHTML = `<div><strong>Convite aceite · falta entrar na sala</strong><small>${esc(i.host)} · ${esc(i.room_code)} · ${money(i.bet_amount)} MZN</small></div><button type="button" data-rf-recover="${esc(i.id)}">Entrar na sala</button>`;
  }

  async function refresh() {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token || busy) return;
    try {
      const status = await rpc('jl_ludo_my_status', {p_token:token});
      ensureRecovery(status?.invites || []);
      if (!status?.active_room_id) {
        roomState = null;
        inviteState = null;
        $('#roomFlowPanel')?.remove();
        return;
      }
      roomState = await rpc('jl_ludo_sync_room', {p_token:token,p_room:status.active_room_id});
      if (!roomState?.room) return;
      inviteState = await rpc('jl_ludo_room_invites', {p_token:token,p_room:roomState.room.id});
      render(roomState, inviteState);
    } catch (_) {}
  }

  async function doAction(action) {
    if (!roomState?.room || busy) return;
    const token = localStorage.getItem(TOKEN_KEY);
    const r = roomState.room;
    busy = true;
    $$('.rf-btn,.rf-mini').forEach(b => b.disabled = true);
    try {
      if (action === 'accept-rules') {
        roomState = await rpc('jl_ludo_accept_rules', {p_token:token,p_room:r.id,p_accept:true});
        toast('Regras aceites.','success');
      } else if (action === 'fund') {
        roomState = await rpc('jl_ludo_commit_stake', {p_token:token,p_room:r.id});
        toast('Aposta confirmada.','success');
      } else if (action === 'roll') {
        roomState = await rpc('jl_ludo_roll', {p_token:token,p_room:r.id});
      } else if (action === 'invite') {
        $('.invite-panel')?.scrollIntoView({behavior:'smooth',block:'center'});
        setTimeout(() => $('#searchPlayer')?.focus({preventScroll:true}), 450);
      } else if (action === 'rules') {
        $('.rules-panel')?.scrollIntoView({behavior:'smooth',block:'center'});
      } else if (action === 'broadcast') {
        if (!r.is_public) {
          toast('Esta sala é privada. Convide jogadores pelo nome/código ou copie o código da sala.','error');
        } else {
          await rpc('jl_ludo_rebroadcast_challenge', {p_token:token,p_room:r.id});
          toast('Sala anunciada para todos por 60 segundos.','success');
        }
      }
      await refresh();
    } catch (e) {
      toast(e.message,'error');
    } finally {
      busy = false;
      $$('.rf-btn,.rf-mini').forEach(b => b.disabled = false);
    }
  }

  function bind() {
    document.addEventListener('click', async (event) => {
      const actionButton = event.target.closest('[data-rf-action]');
      if (actionButton) {
        event.preventDefault();
        await doAction(actionButton.dataset.rfAction);
        return;
      }
      const recover = event.target.closest('[data-rf-recover]');
      if (recover && !busy) {
        event.preventDefault();
        const token = localStorage.getItem(TOKEN_KEY);
        busy = true;
        recover.disabled = true;
        try {
          const result = await rpc('jl_ludo_accept_invite', {p_token:token,p_invitation:recover.dataset.rfRecover,p_accept:true});
          if (result?.room) toast('Entrada na sala recuperada.','success');
          setTimeout(() => location.reload(), 180);
        } catch (e) {
          toast(e.message,'error');
          recover.disabled = false;
          busy = false;
        }
      }
    });
  }

  function init() {
    injectStyles();
    bind();
    refresh();
    clearInterval(timer);
    timer = setInterval(refresh, 1500);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, {once:true});
  else init();
})();
