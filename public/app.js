const $ = selector => document.querySelector(selector);
const API_BASE = 'https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-api';
const MESSAGES_API_BASE = 'https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-messages';

const state = {
  playerId: localStorage.getItem('jl_player_id') || '',
  playerToken: localStorage.getItem('jl_player_token') || '',
  player: null,
  selectedNumber: null,
  pendingAmount: Number(localStorage.getItem('jl_pending_amount') || 10),
  pendingBet: false
};

const authGate = $('#authGate');
const gameArea = $('#gameArea');
const preBetMessage = $('#preBetMessage');
const authMessage = $('#authMessage');
const gameMessage = $('#gameMessage');
const creditMessage = $('#creditMessage');
const withdrawalMessage = $('#withdrawalMessage');
const messageStatus = $('#messageStatus');

function setMessage(el, text = '', type = '') {
  if (!el) return;
  el.textContent = text;
  el.className = `message ${type}`.trim();
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
  const base = url.startsWith('/api/messages/') ? MESSAGES_API_BASE : API_BASE;
  const target = url.startsWith('/api/') ? `${base}${url}` : url;
  const response = await fetch(target, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(state.playerToken ? { 'X-Player-Token': state.playerToken } : {}),
      ...(options.headers || {})
    }
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || 'Não foi possível concluir o pedido.');
  return data;
}

function formatDate(value) {
  if (!value) return '—';
  return new Intl.DateTimeFormat('pt-MZ', {
    day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit'
  }).format(new Date(value));
}
function formatNumber(value) {
  return Number(value || 0).toLocaleString('pt-MZ', { maximumFractionDigits: 2 });
}
function formatMts(value) { return `${formatNumber(value)} MTS`; }

function renderNumbers() {
  const grid = $('#numberGrid');
  grid.innerHTML = '';
  for (let number = 0; number <= 10; number += 1) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `number-button ${state.selectedNumber === number ? 'selected' : ''}`;
    button.textContent = number;
    button.setAttribute('aria-pressed', state.selectedNumber === number ? 'true' : 'false');
    button.addEventListener('click', () => {
      state.selectedNumber = number;
      renderNumbers();
      $('#selectionLabel').textContent = `Escolhido: ${number}`;
      setMessage(preBetMessage);
    });
    grid.appendChild(button);
  }
}

function showAuth() {
  authGate.classList.remove('hidden');
  setTimeout(() => authGate.scrollIntoView({ behavior: 'smooth', block: 'start' }), 50);
}
function hideAuth() {
  authGate.classList.add('hidden');
  setMessage(authMessage);
}
function saveSession(data) {
  state.playerId = data.player.id;
  state.playerToken = data.token;
  localStorage.setItem('jl_player_id', state.playerId);
  localStorage.setItem('jl_player_token', state.playerToken);
}
function clearSession() {
  localStorage.removeItem('jl_player_id');
  localStorage.removeItem('jl_player_token');
  state.playerId = '';
  state.playerToken = '';
  state.player = null;
  gameArea.classList.add('hidden');
}

function renderWithdrawals(items = []) {
  const history = $('#withdrawalHistory');
  if (!items.length) {
    history.className = 'history-list empty-state';
    history.textContent = 'Ainda não há pedidos.';
    return;
  }
  const labels = { pending: 'Pendente', approved: 'Aprovado', rejected: 'Rejeitado' };
  history.className = 'history-list';
  history.innerHTML = items.map(item => `
    <div class="history-row">
      <span>${formatDate(item.createdAt)}</span>
      <span>Valor <strong>${formatMts(item.amount)}</strong></span>
      <strong>${labels[item.status] || item.status}</strong>
    </div>
  `).join('');
}

function renderMessages(items = []) {
  const history = $('#messageHistory');
  if (!items.length) {
    history.className = 'history-list empty-state';
    history.textContent = 'Ainda não há mensagens.';
    return;
  }
  history.className = 'history-list';
  history.innerHTML = items.map(item => `
    <div class="history-row" style="grid-template-columns:120px minmax(0,1fr) 130px">
      <strong style="color:${item.sender === 'admin' ? 'var(--accent-2)' : 'var(--info)'}">${item.sender === 'admin' ? 'Administração' : 'Você'}</strong>
      <span style="overflow-wrap:anywhere">${escapeHtml(item.body)}</span>
      <span>${formatDate(item.createdAt)}</span>
    </div>
  `).join('');
}

async function loadMessages() {
  if (!state.playerId || !state.playerToken) return;
  try {
    const data = await request(`/api/messages/${encodeURIComponent(state.playerId)}`);
    renderMessages(data.messages || []);
  } catch (error) {
    setMessage(messageStatus, error.message, 'error');
  }
}

function renderPlayer(data) {
  state.player = data.player;
  $('#playerDisplay').textContent = data.player.name;
  $('#playerPhoneDisplay').textContent = data.player.phone ? `+${data.player.phone}` : '';
  $('#balanceDisplay').textContent = formatNumber(data.player.balance);
  $('#availableDisplay').textContent = formatNumber(data.availableBalance ?? data.player.balance);
  $('#reservedDisplay').textContent = formatNumber(data.reservedBalance || 0);

  const history = $('#betHistory');
  const bets = data.bets || [];
  if (!bets.length) {
    history.className = 'history-list empty-state';
    history.textContent = 'Ainda não há jogadas.';
  } else {
    history.className = 'history-list';
    history.innerHTML = bets.map(bet => `
      <div class="history-row">
        <span>${formatDate(bet.createdAt)}</span>
        <span>Escolhido <strong>${bet.selectedNumber}</strong></span>
        <span>Sorteado <strong>${bet.drawnNumber}</strong></span>
        <span>Aposta <strong>${formatMts(bet.amount)}</strong></span>
        <strong class="${bet.won ? 'win' : 'loss'}">${bet.won ? `+${formatMts(bet.payout)}` : 'Não ganhou'}</strong>
      </div>
    `).join('');
  }
  renderWithdrawals(data.withdrawals || []);
  gameArea.classList.remove('hidden');
  hideAuth();
  loadMessages();
}

async function loadPlayer() {
  if (!state.playerId || !state.playerToken) {
    gameArea.classList.add('hidden');
    return false;
  }
  try {
    const data = await request(`/api/players/${encodeURIComponent(state.playerId)}`);
    renderPlayer(data);
    return true;
  } catch {
    clearSession();
    return false;
  }
}

async function placePendingBet() {
  if (!state.playerId || !state.playerToken) {
    showAuth();
    return;
  }
  if (state.selectedNumber === null) {
    setMessage(preBetMessage, 'Escolha primeiro uma bola de 0 a 10.', 'error');
    return;
  }
  const value = Number($('#preBetAmount').value);
  if (!Number.isFinite(value) || value < 1) {
    setMessage(preBetMessage, 'Informe um valor válido.', 'error');
    return;
  }

  const button = $('#startBetButton');
  button.disabled = true;
  button.textContent = 'Apostando...';
  setMessage(preBetMessage);

  try {
    const data = await request('/api/bets', {
      method: 'POST',
      body: JSON.stringify({
        playerId: state.playerId,
        number: state.selectedNumber,
        amount: value
      })
    });
    $('#chosenResult').textContent = data.bet.selectedNumber;
    $('#drawnResult').textContent = data.bet.drawnNumber;
    $('#winResult').textContent = data.bet.won ? `Ganhou ${formatMts(data.bet.payout)}` : 'Não ganhou';
    $('#drawResult').classList.remove('hidden');
    setMessage(gameMessage, data.bet.won ? 'Acertou o Número Lendário!' : 'O número não coincidiu desta vez.', data.bet.won ? 'success' : '');
    state.pendingBet = false;
    await loadPlayer();
    gameArea.scrollIntoView({ behavior: 'smooth', block: 'start' });
  } catch (error) {
    setMessage(preBetMessage, error.message, 'error');
    setMessage(gameMessage, error.message, 'error');
    await loadPlayer();
    if (/saldo/i.test(error.message)) {
      const card = $('#creditForm')?.closest('.credits-card');
      card?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  } finally {
    button.disabled = false;
    button.textContent = 'Apostar';
  }
}

$('#preBetForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (state.selectedNumber === null) {
    setMessage(preBetMessage, 'Escolha primeiro uma bola de 0 a 10.', 'error');
    return;
  }
  const value = Number($('#preBetAmount').value);
  if (!Number.isFinite(value) || value < 1) {
    setMessage(preBetMessage, 'Informe um valor válido.', 'error');
    return;
  }
  state.pendingAmount = value;
  state.pendingBet = true;
  localStorage.setItem('jl_pending_amount', String(value));

  if (!state.playerId || !state.playerToken) {
    showAuth();
    return;
  }
  await placePendingBet();
});

$('#registerForm').addEventListener('submit', async event => {
  event.preventDefault();
  const pin = $('#registerPin').value;
  const confirmPin = $('#registerPinConfirm').value;
  if (pin !== confirmPin) {
    setMessage(authMessage, 'Os PINs não coincidem.', 'error');
    return;
  }
  setMessage(authMessage, 'Criando conta...');
  try {
    const data = await request('/api/auth/register', {
      method: 'POST',
      body: JSON.stringify({
        name: $('#registerName').value,
        phone: $('#registerPhone').value,
        pin,
        confirmPin
      })
    });
    saveSession(data);
    setMessage(authMessage, 'Conta criada.', 'success');
    await loadPlayer();
    if (state.pendingBet) await placePendingBet();
  } catch (error) {
    setMessage(authMessage, error.message, 'error');
  }
});

$('#showLogin').addEventListener('click', () => {
  $('#loginForm').classList.toggle('hidden');
});

$('#loginForm').addEventListener('submit', async event => {
  event.preventDefault();
  setMessage(authMessage, 'Entrando...');
  try {
    const data = await request('/api/auth/login', {
      method: 'POST',
      body: JSON.stringify({
        phone: $('#loginPhone').value,
        pin: $('#loginPin').value
      })
    });
    saveSession(data);
    setMessage(authMessage, 'Sessão iniciada.', 'success');
    await loadPlayer();
    if (state.pendingBet) await placePendingBet();
  } catch (error) {
    setMessage(authMessage, error.message, 'error');
  }
});

$('#switchPlayer').addEventListener('click', () => {
  clearSession();
  showAuth();
});

$('#refreshPlayer').addEventListener('click', loadPlayer);
$('#refreshMessages').addEventListener('click', loadMessages);

$('#messageForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (!state.playerId) return;
  const input = $('#messageInput');
  const message = input.value.trim();
  if (!message) return;
  setMessage(messageStatus, 'Enviando...');
  try {
    await request(`/api/messages/${encodeURIComponent(state.playerId)}`, {
      method: 'POST',
      body: JSON.stringify({ message })
    });
    input.value = '';
    setMessage(messageStatus, 'Mensagem enviada.', 'success');
    await loadMessages();
  } catch (error) {
    setMessage(messageStatus, error.message, 'error');
  }
});

$('#creditForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (!state.playerId) return;
  setMessage(creditMessage, 'Enviando pedido...');
  try {
    const data = await request('/api/credit-requests', {
      method: 'POST',
      body: JSON.stringify({
        playerId: state.playerId,
        amount: $('#creditAmount').value,
        note: $('#creditNote').value
      })
    });
    setMessage(creditMessage, `Pedido de ${formatMts(data.request.amount)} enviado. Aguarda aprovação.`, 'success');
    $('#creditNote').value = '';
    await loadPlayer();
  } catch (error) {
    setMessage(creditMessage, error.message, 'error');
  }
});

$('#withdrawalForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (!state.playerId) return;
  setMessage(withdrawalMessage, 'Enviando pedido...');
  try {
    const data = await request('/api/withdrawals', {
      method: 'POST',
      body: JSON.stringify({
        playerId: state.playerId,
        amount: $('#withdrawalAmount').value
      })
    });
    setMessage(withdrawalMessage, `Pedido de ${formatMts(data.request.amount)} ficou pendente.`, 'success');
    await loadPlayer();
  } catch (error) {
    setMessage(withdrawalMessage, error.message, 'error');
  }
});

$('#preBetAmount').value = String(state.pendingAmount || 10);
renderNumbers();
loadPlayer();
