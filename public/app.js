const $ = selector => document.querySelector(selector);
const API_BASE = 'https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-api';

const state = {
  playerId: localStorage.getItem('jl_player_id') || '',
  playerToken: localStorage.getItem('jl_player_token') || '',
  player: null,
  selectedNumber: null
};

const playerGate = $('#playerGate');
const gameArea = $('#gameArea');
const gateMessage = $('#gateMessage');
const gameMessage = $('#gameMessage');
const creditMessage = $('#creditMessage');
const withdrawalMessage = $('#withdrawalMessage');

function setMessage(el, text = '', type = '') {
  el.textContent = text;
  el.className = `message ${type}`.trim();
}

async function request(url, options = {}) {
  const target = url.startsWith('/api/') ? `${API_BASE}${url}` : url;
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

function formatMts(value) {
  return `${formatNumber(value)} MTS`;
}

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
      setMessage(gameMessage);
    });
    grid.appendChild(button);
  }
}

function renderWithdrawals(items = []) {
  const history = $('#withdrawalHistory');
  if (!items.length) {
    history.className = 'history-list empty-state';
    history.textContent = 'Ainda não há pedidos de levantamento.';
    return;
  }
  const labels = {
    pending: 'Pendente',
    approved: 'Aprovado',
    rejected: 'Rejeitado'
  };
  history.className = 'history-list';
  history.innerHTML = items.map(item => `
    <div class="history-row">
      <span>${formatDate(item.createdAt)}</span>
      <span>Valor <strong>${formatMts(item.amount)}</strong></span>
      <strong>${labels[item.status] || item.status}</strong>
    </div>
  `).join('');
}

function renderPlayer(data) {
  state.player = data.player;
  $('#playerDisplay').textContent = data.player.name;
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
  playerGate.classList.add('hidden');
  gameArea.classList.remove('hidden');
}

function clearPlayerSession() {
  localStorage.removeItem('jl_player_id');
  localStorage.removeItem('jl_player_token');
  state.playerId = '';
  state.playerToken = '';
  state.player = null;
}

async function loadPlayer() {
  if (!state.playerId || !state.playerToken) {
    playerGate.classList.remove('hidden');
    gameArea.classList.add('hidden');
    return;
  }
  try {
    const data = await request(`/api/players/${encodeURIComponent(state.playerId)}`);
    renderPlayer(data);
  } catch (error) {
    clearPlayerSession();
    playerGate.classList.remove('hidden');
    gameArea.classList.add('hidden');
    setMessage(gateMessage, 'A sessão anterior não foi encontrada. Crie um jogador novamente.', 'error');
  }
}

$('#playerForm').addEventListener('submit', async event => {
  event.preventDefault();
  setMessage(gateMessage, 'Criando jogador...');
  try {
    const data = await request('/api/players', {
      method: 'POST',
      body: JSON.stringify({ name: $('#playerName').value })
    });
    state.playerId = data.player.id;
    state.playerToken = data.token;
    localStorage.setItem('jl_player_id', state.playerId);
    localStorage.setItem('jl_player_token', state.playerToken);
    await loadPlayer();
  } catch (error) {
    setMessage(gateMessage, error.message, 'error');
  }
});

$('#switchPlayer').addEventListener('click', () => {
  clearPlayerSession();
  state.selectedNumber = null;
  $('#drawResult').classList.add('hidden');
  $('#selectionLabel').textContent = 'Nenhum escolhido';
  renderNumbers();
  gameArea.classList.add('hidden');
  playerGate.classList.remove('hidden');
  $('#playerName').focus();
});

$('#refreshPlayer').addEventListener('click', loadPlayer);

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
    setMessage(creditMessage, `Pedido de ${formatMts(data.request.amount)} de demonstração enviado. Aguarda aprovação do administrador.`, 'success');
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
    setMessage(withdrawalMessage, `Pedido de ${formatMts(data.request.amount)} ficou pendente para aprovação.`, 'success');
    await loadPlayer();
  } catch (error) {
    setMessage(withdrawalMessage, error.message, 'error');
  }
});

$('#betForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (state.selectedNumber === null) {
    setMessage(gameMessage, 'Escolha primeiro um número de 0 a 10.', 'error');
    return;
  }

  const playButton = $('#playButton');
  playButton.disabled = true;
  playButton.textContent = 'Sorteando...';
  setMessage(gameMessage);

  try {
    const data = await request('/api/bets', {
      method: 'POST',
      body: JSON.stringify({
        playerId: state.playerId,
        number: state.selectedNumber,
        amount: $('#betAmount').value
      })
    });

    $('#chosenResult').textContent = data.bet.selectedNumber;
    $('#drawnResult').textContent = data.bet.drawnNumber;
    $('#winResult').textContent = data.bet.won
      ? `Ganhou ${formatMts(data.bet.payout)}`
      : 'Não ganhou';
    $('#drawResult').classList.remove('hidden');

    if (data.bet.won) {
      setMessage(gameMessage, 'Acertou o Número Lendário!', 'success');
    } else {
      setMessage(gameMessage, 'O número não coincidiu desta vez.');
    }
    await loadPlayer();
  } catch (error) {
    setMessage(gameMessage, error.message, 'error');
  } finally {
    playButton.disabled = false;
    playButton.textContent = 'Sortear agora';
  }
});

renderNumbers();
loadPlayer();