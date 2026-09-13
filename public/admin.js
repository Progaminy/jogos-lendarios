const $ = selector => document.querySelector(selector);

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

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

async function request(url, options = {}) {
  const response = await fetch(url, {
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
    ['Créditos apostados', formatNumber(stats.totalStaked)],
    ['Créditos pagos', formatNumber(stats.totalPayout)],
    ['Créditos pendentes', stats.pendingCredits],
    ['Levantamentos pendentes', stats.pendingWithdrawals],
    ['Créditos reservados', formatNumber(stats.reservedCredits)]
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
      <td><strong>${formatNumber(item.amount)}</strong></td>
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
      <td><strong>${formatNumber(item.amount)}</strong></td>
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
      <span>${formatNumber(item.staked)} créditos</span>
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
      <td><strong>${formatNumber(player.balance)}</strong></td>
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
      <td>${formatNumber(bet.amount)}</td>
      <td>${bet.won ? `<strong style="color:var(--success)">Ganhou ${formatNumber(bet.payout)}</strong>` : '<span style="color:var(--muted)">Não ganhou</span>'}</td>
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
      setMessage('Pedido de créditos analisado.', 'success');
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
    const value = window.prompt(`Ajuste do saldo virtual de ${adjustButton.dataset.name}. Use valor positivo para adicionar e negativo para retirar.`);
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
      setMessage('Saldo virtual ajustado.', 'success');
    } catch (error) {
      setMessage(error.message, 'error');
    }
  }
});

loadDashboard();
