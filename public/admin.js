const $ = selector => document.querySelector(selector);
const API_BASE = 'https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-api';

const state = {
  token: sessionStorage.getItem('jl_admin_token') || ''
};

function setMessage(text = '', type = '') {
  const el = $('#adminMessage');
  el.textContent = text;
  el.className = `message ${type}`.trim();
}

function setLoginMessage(text = '', type = '') {
  const el = $('#loginMessage');
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

function formatMts(value) {
  return `${formatNumber(value)} MTS`;
}

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

async function request(url, options = {}) {
  const target = url.startsWith('/api/') ? `${API_BASE}${url}` : url;
  const response = await fetch(target, {
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

function showDashboard() {
  $('#loginPanel').classList.add('hidden');
  $('#dashboard').classList.remove('hidden');
}

function showLogin() {
  $('#dashboard').classList.add('hidden');
  $('#loginPanel').classList.remove('hidden');
}

function renderStats(stats) {
  const items = [
    ['Jogadores', stats.players],
    ['Apostas', stats.bets],
    ['MTS apostados', formatMts(stats.totalStaked)],
    ['MTS pagos', formatMts(stats.totalPayout)],
    ['Pedidos de saldo pendentes', stats.pendingCredits],
    ['Levantamentos pendentes', stats.pendingWithdrawals],
    ['MTS reservados', formatMts(stats.reservedCredits)]
  ];
  $('#statsGrid').innerHTML = items.map(([label, value]) => `
    <div class="stat-card"><span>${label}</span><strong>${value}</strong></div>
  `).join('');
}

function renderCredits(requests) {
  const rows = $('#creditRows');
  if (!requests.length) {
    rows.innerHTML = '<tr><td colspan="5">Nenhum pedido pendente.</td></tr>';
    return;
  }
  rows.innerHTML = requests.map(item => `
    <tr>
      <td>${escapeHtml(item.playerName)}</td>
      <td><strong>${formatMts(item.amount)}</strong></td>
      <td>${escapeHtml(item.note || '—')}</td>
      <td>${formatDate(item.createdAt)}</td>
      <td>
        <div class="actions">
          <button class="button success" data-credit-action="approve" data-id="${escapeHtml(item.id)}">Aprovar</button>
          <button class="button danger" data-credit-action="deny" data-id="${escapeHtml(item.id)}">Rejeitar</button>
        </div>
      </td>
    </tr>
  `).join('');
}

function renderWithdrawals(requests) {
  const rows = $('#withdrawalRows');
  if (!requests.length) {
    rows.innerHTML = '<tr><td colspan="4">Nenhum levantamento pendente.</td></tr>';
    return;
  }
  rows.innerHTML = requests.map(item => `
    <tr>
      <td>${escapeHtml(item.playerName)}</td>
      <td><strong>${formatMts(item.amount)}</strong></td>
      <td>${formatDate(item.createdAt)}</td>
      <td>
        <div class="actions">
          <button class="button success" data-withdrawal-action="approve" data-id="${escapeHtml(item.id)}">Aprovar</button>
          <button class="button danger" data-withdrawal-action="deny" data-id="${escapeHtml(item.id)}">Rejeitar</button>
        </div>
      </td>
    </tr>
  `).join('');
}

function renderNumberStats(items) {
  $('#numberStats').innerHTML = items.map(item => `
    <div class="number-stat">
      <strong>${item.number}</strong>
      <span>${item.bets} apostas</span>
      <span>${formatMts(item.staked)}</span>
    </div>
  `).join('');
}

function renderPlayers(players) {
  const rows = $('#playerRows');
  if (!players.length) {
    rows.innerHTML = '<tr><td colspan="5">Nenhum jogador.</td></tr>';
    return;
  }
  rows.innerHTML = players.map(player => `
    <tr>
      <td>${escapeHtml(player.name)}</td>
      <td><strong>${formatMts(player.balance)}</strong></td>
      <td>${player.blocked ? '<span class="status denied">Bloqueado</span>' : '<span class="status approved">Ativo</span>'}</td>
      <td>${formatDate(player.createdAt)}</td>
      <td>
        <div class="actions">
          <button class="button ghost" data-adjust="1" data-id="${escapeHtml(player.id)}" data-name="${escapeHtml(player.name)}">Ajustar saldo</button>
          <button class="button ${player.blocked ? 'success' : 'danger'}" data-block="${player.blocked ? 'unblock' : 'block'}" data-id="${escapeHtml(player.id)}">
            ${player.blocked ? 'Desbloquear' : 'Bloquear'}
          </button>
        </div>
      </td>
    </tr>
  `).join('');
}

function renderBets(bets) {
  const rows = $('#betRows');
  if (!bets.length) {
    rows.innerHTML = '<tr><td colspan="6">Nenhuma aposta.</td></tr>';
    return;
  }
  rows.innerHTML = bets.map(bet => `
    <tr>
      <td>${formatDate(bet.createdAt)}</td>
      <td>${escapeHtml(bet.playerName)}</td>
      <td>${bet.selectedNumber}</td>
      <td><strong>${bet.drawnNumber}</strong></td>
      <td>${formatMts(bet.amount)}</td>
      <td>${bet.won ? `<strong style="color:var(--success)">Ganhou ${formatMts(bet.payout)}</strong>` : '<span style="color:var(--muted)">Não ganhou</span>'}</td>
    </tr>
  `).join('');
}

function renderAudit(items) {
  const rows = $('#auditRows');
  if (!items.length) {
    rows.innerHTML = '<tr><td colspan="3">Nenhum registo.</td></tr>';
    return;
  }
  rows.innerHTML = items.map(item => `
    <tr>
      <td>${formatDate(item.createdAt)}</td>
      <td><code>${escapeHtml(item.action)}</code></td>
      <td><code>${escapeHtml(JSON.stringify(item.details))}</code></td>
    </tr>
  `).join('');
}

async function loadDashboard() {
  if (!state.token) {
    showLogin();
    return;
  }
  try {
    const data = await request('/api/admin/overview');
    renderStats(data.stats);
    renderCredits(data.pendingCredits);
    renderWithdrawals(data.pendingWithdrawals);
    renderNumberStats(data.numberStats);
    renderPlayers(data.players);
    renderBets(data.recentBets);
    renderAudit(data.audit);
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
    const data = await request('/api/admin/login', {
      method: 'POST',
      body: JSON.stringify({ code: $('#adminCode').value })
    });
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

$('#dashboard').addEventListener('click', async event => {
  const creditButton = event.target.closest('[data-credit-action]');
  if (creditButton) {
    creditButton.disabled = true;
    try {
      await request(`/api/admin/credit-requests/${encodeURIComponent(creditButton.dataset.id)}/${creditButton.dataset.creditAction}`, { method: 'POST' });
      await loadDashboard();
      setMessage('Pedido de saldo analisado.', 'success');
    } catch (error) {
      setMessage(error.message, 'error');
      creditButton.disabled = false;
    }
    return;
  }

  const withdrawalButton = event.target.closest('[data-withdrawal-action]');
  if (withdrawalButton) {
    withdrawalButton.disabled = true;
    try {
      await request(`/api/admin/withdrawals/${encodeURIComponent(withdrawalButton.dataset.id)}/${withdrawalButton.dataset.withdrawalAction}`, { method: 'POST' });
      await loadDashboard();
      setMessage('Pedido de levantamento analisado.', 'success');
    } catch (error) {
      setMessage(error.message, 'error');
      withdrawalButton.disabled = false;
    }
    return;
  }

  const blockButton = event.target.closest('[data-block]');
  if (blockButton) {
    blockButton.disabled = true;
    try {
      await request(`/api/admin/players/${encodeURIComponent(blockButton.dataset.id)}/${blockButton.dataset.block}`, { method: 'POST' });
      await loadDashboard();
      setMessage('Estado do jogador atualizado.', 'success');
    } catch (error) {
      setMessage(error.message, 'error');
      blockButton.disabled = false;
    }
    return;
  }

  const adjustButton = event.target.closest('[data-adjust]');
  if (adjustButton) {
    const value = window.prompt(`Ajuste do saldo de demonstração de ${adjustButton.dataset.name} em MTS. Use valor positivo para adicionar e negativo para retirar.`);
    if (value === null) return;
    const delta = Number(value);
    if (!Number.isFinite(delta) || delta === 0) {
      setMessage('Informe um ajuste numérico diferente de zero.', 'error');
      return;
    }
    try {
      await request(`/api/admin/players/${encodeURIComponent(adjustButton.dataset.id)}/adjust-balance`, {
        method: 'POST',
        body: JSON.stringify({ delta })
      });
      await loadDashboard();
      setMessage('Saldo de demonstração ajustado.', 'success');
    } catch (error) {
      setMessage(error.message, 'error');
    }
  }
});

loadDashboard();