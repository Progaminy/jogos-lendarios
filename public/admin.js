const $ = selector => document.querySelector(selector);
const API_BASE = 'https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-api';
const MESSAGES_API_BASE = 'https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-messages';
const ROUNDS_API_BASE = 'https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-rounds';

const state = {
  token: sessionStorage.getItem('jl_admin_token') || '',
  round: null,
  roundClosesAt: null
};

function setMessage(text = '', type = '') {
  const el = $('#adminMessage');
  if (!el) return;
  el.textContent = text;
  el.className = `message ${type}`.trim();
}
function setLoginMessage(text = '', type = '') {
  const el = $('#loginMessage');
  if (!el) return;
  el.textContent = text;
  el.className = `message ${type}`.trim();
}
function formatDate(value) {
  if (!value) return '—';
  return new Intl.DateTimeFormat('pt-MZ', {
    day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit'
  }).format(new Date(value));
}
function formatNumber(value) {
  return Number(value || 0).toLocaleString('pt-MZ', { maximumFractionDigits: 2 });
}
function formatMts(value) { return `${formatNumber(value)} MTS`; }
function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;').replaceAll("'", '&#039;');
}

async function fetchJson(base, url, options = {}) {
  const response = await fetch(`${base}${url}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(state.token ? { Authorization: `Bearer ${state.token}` } : {}),
      ...(options.headers || {})
    }
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 401 && url !== '/api/admin/login') logout(false);
    throw new Error(data.error || 'Não foi possível concluir o pedido.');
  }
  return data;
}
function request(url, options = {}) {
  const base = url.startsWith('/api/admin/messages') ? MESSAGES_API_BASE : API_BASE;
  return fetchJson(base, url, options);
}
function roundRequest(url, options = {}) {
  return fetchJson(ROUNDS_API_BASE, url, options);
}

function showDashboard() {
  $('#loginPanel').classList.add('hidden');
  $('#dashboard').classList.remove('hidden');
}
function showLogin() {
  $('#dashboard').classList.add('hidden');
  $('#loginPanel').classList.remove('hidden');
}

function ensureRoundControl() {
  if ($('#roundControlCard')) return;
  const grid = document.querySelector('.admin-grid');
  if (!grid) return;
  const section = document.createElement('section');
  section.id = 'roundControlCard';
  section.className = 'card admin-card full-span';
  section.innerHTML = `
    <div class="section-heading">
      <div>
        <p class="eyebrow">CONTROLO DA RODADA</p>
        <h2>Abrir, fechar, sortear e publicar</h2>
      </div>
      <span id="roundStatusPill" class="selection-pill">Sem rodada</span>
    </div>
    <div id="roundSummary" style="margin:12px 0 18px;color:var(--muted)">Nenhuma rodada carregada.</div>
    <div class="stack-form" style="max-width:760px">
      <label>
        Cronómetro em minutos
        <input id="roundMinutes" type="number" min="1" max="1440" step="1" value="5" inputmode="numeric">
      </label>
      <div class="actions" style="flex-wrap:wrap">
        <button id="openRound" class="button success" type="button">Abrir jogo</button>
        <button id="closeRound" class="button danger" type="button">Fechar apostas</button>
        <button id="drawRound" class="button secondary" type="button">Sortear número</button>
        <button id="publishRound" class="button primary" type="button">Publicar resultado</button>
      </div>
    </div>
    <p style="color:var(--muted);margin-top:14px">O sorteio pode ser executado apenas uma vez por rodada. Depois disso, o número fica bloqueado até a publicação.</p>
    <div id="roundDrawnNumber" style="font-size:1.1rem;font-weight:800;margin-top:12px"></div>
    <div id="roundWinners" class="history-list empty-state" style="margin-top:16px">Vencedores aparecerão aqui depois da publicação.</div>
  `;
  grid.prepend(section);
}

function renderStats(stats, messageCount = 0) {
  const items = [
    ['Jogadores', stats.players], ['Apostas', stats.bets],
    ['MTS apostados', formatMts(stats.totalStaked)], ['MTS pagos', formatMts(stats.totalPayout)],
    ['Pedidos de saldo pendentes', stats.pendingCredits], ['Levantamentos pendentes', stats.pendingWithdrawals],
    ['MTS reservados', formatMts(stats.reservedCredits)], ['Mensagens', messageCount]
  ];
  $('#statsGrid').innerHTML = items.map(([label, value]) => `<div class="stat-card"><span>${label}</span><strong>${value}</strong></div>`).join('');
}

function renderCredits(requests) {
  const rows = $('#creditRows');
  rows.innerHTML = requests.length ? requests.map(item => `
    <tr>
      <td>${escapeHtml(item.playerName)}</td><td><strong>${formatMts(item.amount)}</strong></td>
      <td>${escapeHtml(item.note || '—')}</td><td>${formatDate(item.createdAt)}</td>
      <td><div class="actions"><button class="button success" data-credit-action="approve" data-id="${escapeHtml(item.id)}">Aprovar</button><button class="button danger" data-credit-action="deny" data-id="${escapeHtml(item.id)}">Rejeitar</button></div></td>
    </tr>`).join('') : '<tr><td colspan="5">Nenhum pedido pendente.</td></tr>';
}

function renderWithdrawals(requests) {
  const rows = $('#withdrawalRows');
  rows.innerHTML = requests.length ? requests.map(item => `
    <tr><td>${escapeHtml(item.playerName)}</td><td><strong>${formatMts(item.amount)}</strong></td><td>${formatDate(item.createdAt)}</td>
    <td><div class="actions"><button class="button success" data-withdrawal-action="approve" data-id="${escapeHtml(item.id)}">Aprovar</button><button class="button danger" data-withdrawal-action="deny" data-id="${escapeHtml(item.id)}">Rejeitar</button></div></td></tr>`).join('') : '<tr><td colspan="4">Nenhum levantamento pendente.</td></tr>';
}

function renderNumberStats(items = []) {
  $('#numberStats').innerHTML = items.map(item => `
    <div class="number-stat">
      <strong>${item.number}</strong>
      <span>${item.bets} aposta${item.bets === 1 ? '' : 's'}</span>
      <span><strong>${formatMts(item.staked)}</strong> total</span>
    </div>`).join('');
}

function renderPlayers(players) {
  const rows = $('#playerRows');
  rows.innerHTML = players.length ? players.map(player => `
    <tr>
      <td>${escapeHtml(player.name)}</td><td><strong>${formatMts(player.balance)}</strong></td>
      <td>${player.blocked ? '<span class="status denied">Bloqueado</span>' : '<span class="status approved">Ativo</span>'}</td>
      <td>${formatDate(player.createdAt)}</td>
      <td><div class="actions"><button class="button ghost" data-adjust="1" data-id="${escapeHtml(player.id)}" data-name="${escapeHtml(player.name)}">Ajustar saldo</button><button class="button ${player.blocked ? 'success' : 'danger'}" data-block="${player.blocked ? 'unblock' : 'block'}" data-id="${escapeHtml(player.id)}">${player.blocked ? 'Desbloquear' : 'Bloquear'}</button></div></td>
    </tr>`).join('') : '<tr><td colspan="5">Nenhum jogador.</td></tr>';
}

function renderBets(bets) {
  const rows = $('#betRows');
  rows.innerHTML = bets.length ? bets.map(bet => {
    const pending = bet.drawnNumber === null || bet.drawnNumber === undefined;
    return `<tr>
      <td>${formatDate(bet.createdAt)}</td><td>${escapeHtml(bet.playerName)}</td><td>${bet.selectedNumber}</td>
      <td><strong>${pending ? 'Pendente' : bet.drawnNumber}</strong></td><td>${formatMts(bet.amount)}</td>
      <td>${pending ? '<span style="color:var(--muted)">Aguardando publicação</span>' : bet.won ? `<strong style="color:var(--success)">Ganhou ${formatMts(bet.payout)}</strong>` : '<span style="color:var(--muted)">Não ganhou</span>'}</td>
    </tr>`;
  }).join('') : '<tr><td colspan="6">Nenhuma aposta.</td></tr>';
}

function renderAudit(items) {
  const rows = $('#auditRows');
  rows.innerHTML = items.length ? items.map(item => `<tr><td>${formatDate(item.createdAt)}</td><td><code>${escapeHtml(item.action)}</code></td><td><code>${escapeHtml(JSON.stringify(item.details))}</code></td></tr>`).join('') : '<tr><td colspan="3">Nenhum registo.</td></tr>';
}

function renderMessageThreads(messages = []) {
  const root = $('#messageThreads');
  if (!messages.length) {
    root.className = 'history-list empty-state';
    root.textContent = 'Ainda não há mensagens.';
    return;
  }
  const groups = new Map();
  for (const item of messages) {
    if (!groups.has(item.playerId)) groups.set(item.playerId, { playerId: item.playerId, playerName: item.playerName || 'Jogador', items: [] });
    groups.get(item.playerId).items.push(item);
  }
  root.className = 'history-list';
  root.innerHTML = [...groups.values()].map(thread => `
    <div class="card" style="padding:18px;border-radius:16px">
      <h2 style="margin-bottom:8px">${escapeHtml(thread.playerName)}</h2>
      <div class="history-list">${thread.items.slice(-12).map(item => `<div class="history-row" style="grid-template-columns:100px minmax(0,1fr) 120px"><strong>${item.sender === 'admin' ? 'Admin' : 'Jogador'}</strong><span>${escapeHtml(item.body)}</span><span>${formatDate(item.createdAt)}</span></div>`).join('')}</div>
      <form class="stack-form admin-message-form" data-player-id="${escapeHtml(thread.playerId)}" style="margin-top:14px"><label>Responder<input name="message" maxlength="1000" required></label><button class="button secondary" type="submit">Enviar resposta</button></form>
    </div>`).join('');
}

function updateRoundCountdown() {
  const summary = $('#roundSummary');
  if (!summary || !state.round) return;
  const r = state.round;
  if (r.status === 'open' && r.closesAt) {
    const seconds = Math.max(0, Math.ceil((new Date(r.closesAt).getTime() - Date.now()) / 1000));
    const min = Math.floor(seconds / 60);
    const sec = String(seconds % 60).padStart(2, '0');
    summary.textContent = `Apostas abertas · ${min}:${sec} restantes · ${state.roundBets || 0} apostas · ${formatMts(state.roundStaked || 0)} apostados.`;
  }
}

function renderRoundControl(data) {
  ensureRoundControl();
  state.round = data.round || null;
  state.roundBets = data.bets || 0;
  state.roundStaked = data.totalStaked || 0;
  const r = state.round;
  const pill = $('#roundStatusPill');
  const summary = $('#roundSummary');
  const drawn = $('#roundDrawnNumber');
  const winners = $('#roundWinners');
  const labels = { open: 'Apostas abertas', closed: 'Apostas fechadas', drawn: 'Número sorteado', published: 'Resultado publicado' };
  pill.textContent = r ? labels[r.status] || r.status : 'Sem rodada';
  if (!r) summary.textContent = 'Nenhuma rodada criada. Defina o cronómetro e clique em Abrir jogo.';
  else if (r.status === 'open') summary.textContent = `Apostas abertas · ${data.bets} apostas · ${formatMts(data.totalStaked)} apostados.`;
  else summary.textContent = `${labels[r.status] || r.status} · ${data.bets} apostas · ${formatMts(data.totalStaked)} apostados.`;
  drawn.textContent = r?.drawnNumber === null || r?.drawnNumber === undefined ? '' : `Número sorteado: ${r.drawnNumber}`;

  const list = data.winners || [];
  if (r?.status === 'published') {
    if (!list.length) {
      winners.className = 'history-list empty-state';
      winners.textContent = 'Resultado publicado. Não houve vencedor nesta rodada.';
    } else {
      winners.className = 'history-list';
      winners.innerHTML = `<h3>Vencedores</h3>${list.map(w => `<div class="history-row"><strong>${escapeHtml(w.playerName)}</strong><span>Aposta ${formatMts(w.amount)}</span><strong class="win">Prémio ${formatMts(w.payout)}</strong></div>`).join('')}`;
    }
  } else {
    winners.className = 'history-list empty-state';
    winners.textContent = 'Vencedores aparecerão aqui depois da publicação.';
  }

  $('#openRound').disabled = Boolean(r && r.status !== 'published');
  $('#closeRound').disabled = !r || r.status !== 'open';
  $('#drawRound').disabled = !r || r.status !== 'closed';
  $('#publishRound').disabled = !r || r.status !== 'drawn';
  renderNumberStats(data.numberStats || []);
  updateRoundCountdown();
}

async function loadDashboard() {
  if (!state.token) { showLogin(); return; }
  ensureRoundControl();
  try {
    const [data, roundData, messageData] = await Promise.all([
      request('/api/admin/overview'),
      roundRequest('/api/admin/round-state'),
      request('/api/admin/messages').catch(() => ({ messages: [] }))
    ]);
    renderStats(data.stats, (messageData.messages || []).length);
    renderCredits(data.pendingCredits || []);
    renderWithdrawals(data.pendingWithdrawals || []);
    renderPlayers(data.players || []);
    renderBets(data.recentBets || []);
    renderMessageThreads(messageData.messages || []);
    renderAudit(data.audit || []);
    renderRoundControl(roundData);
    showDashboard();
    setMessage();
  } catch (error) {
    setMessage(error.message, 'error');
  }
}

async function login(event) {
  event.preventDefault();
  setLoginMessage('Validando...');
  try {
    const data = await request('/api/admin/login', { method: 'POST', body: JSON.stringify({ code: $('#adminCode').value }) });
    state.token = data.token;
    sessionStorage.setItem('jl_admin_token', state.token);
    $('#adminCode').value = '';
    setLoginMessage();
    await loadDashboard();
  } catch (error) {
    setLoginMessage(error.message, 'error');
  }
}

async function logout(callServer = true) {
  if (callServer && state.token) {
    try { await request('/api/admin/logout', { method: 'POST' }); } catch {}
  }
  state.token = '';
  sessionStorage.removeItem('jl_admin_token');
  showLogin();
}

$('#adminLoginForm').addEventListener('submit', login);
$('#refreshAdmin').addEventListener('click', loadDashboard);
$('#logoutAdmin').addEventListener('click', () => logout(true));

$('#dashboard').addEventListener('submit', async event => {
  const form = event.target.closest('.admin-message-form');
  if (!form) return;
  event.preventDefault();
  const input = form.querySelector('input[name="message"]');
  const message = input.value.trim();
  if (!message) return;
  try {
    await request(`/api/admin/messages/${encodeURIComponent(form.dataset.playerId)}`, { method: 'POST', body: JSON.stringify({ message }) });
    input.value = '';
    await loadDashboard();
    setMessage('Resposta enviada ao jogador.', 'success');
  } catch (error) { setMessage(error.message, 'error'); }
});

$('#dashboard').addEventListener('click', async event => {
  const id = event.target.id;
  if (['openRound','closeRound','drawRound','publishRound'].includes(id)) {
    event.target.disabled = true;
    try {
      if (id === 'openRound') {
        const raw = $('#roundMinutes').value.trim();
        const minutes = raw ? Number(raw) : null;
        await roundRequest('/api/admin/rounds/open', { method: 'POST', body: JSON.stringify({ minutes }) });
        setMessage('Jogo aberto. Apostas liberadas.', 'success');
      } else if (id === 'closeRound') {
        await roundRequest('/api/admin/rounds/close', { method: 'POST' });
        setMessage('Apostas fechadas.', 'success');
      } else if (id === 'drawRound') {
        await roundRequest('/api/admin/rounds/draw', { method: 'POST' });
        setMessage('Número sorteado e bloqueado. Agora pode publicar o resultado.', 'success');
      } else if (id === 'publishRound') {
        await roundRequest('/api/admin/rounds/publish', { method: 'POST' });
        setMessage('Resultado publicado e prémios de teste adicionados aos vencedores.', 'success');
      }
      await loadDashboard();
    } catch (error) {
      setMessage(error.message, 'error');
      event.target.disabled = false;
    }
    return;
  }

  const creditButton = event.target.closest('[data-credit-action]');
  if (creditButton) {
    try {
      await request(`/api/admin/credit-requests/${encodeURIComponent(creditButton.dataset.id)}/${creditButton.dataset.creditAction}`, { method: 'POST' });
      await loadDashboard();
      setMessage('Pedido de saldo analisado.', 'success');
    } catch (error) { setMessage(error.message, 'error'); }
    return;
  }

  const withdrawalButton = event.target.closest('[data-withdrawal-action]');
  if (withdrawalButton) {
    try {
      await request(`/api/admin/withdrawals/${encodeURIComponent(withdrawalButton.dataset.id)}/${withdrawalButton.dataset.withdrawalAction}`, { method: 'POST' });
      await loadDashboard();
      setMessage('Pedido de levantamento analisado.', 'success');
    } catch (error) { setMessage(error.message, 'error'); }
    return;
  }

  const blockButton = event.target.closest('[data-block]');
  if (blockButton) {
    try {
      await request(`/api/admin/players/${encodeURIComponent(blockButton.dataset.id)}/${blockButton.dataset.block}`, { method: 'POST' });
      await loadDashboard();
    } catch (error) { setMessage(error.message, 'error'); }
    return;
  }

  const adjustButton = event.target.closest('[data-adjust]');
  if (adjustButton) {
    const value = window.prompt(`Ajuste do saldo de teste de ${adjustButton.dataset.name} em MTS. Positivo adiciona, negativo retira.`);
    if (value === null) return;
    const delta = Number(value);
    if (!Number.isFinite(delta) || delta === 0) { setMessage('Informe um ajuste numérico diferente de zero.', 'error'); return; }
    try {
      await request(`/api/admin/players/${encodeURIComponent(adjustButton.dataset.id)}/adjust-balance`, { method: 'POST', body: JSON.stringify({ delta }) });
      await loadDashboard();
      setMessage('Saldo de teste ajustado.', 'success');
    } catch (error) { setMessage(error.message, 'error'); }
  }
});

ensureRoundControl();
loadDashboard();
setInterval(updateRoundCountdown, 1000);
setInterval(() => { if (state.token) loadDashboard(); }, 10000);
