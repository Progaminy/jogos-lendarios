const $ = selector => document.querySelector(selector);

const state = {
  playerId: localStorage.getItem('jl_player_id') || '',
  player: null,
  selectedNumber: null
};

const playerGate = $('#playerGate');
const gameArea = $('#gameArea');
const gateMessage = $('#gateMessage');
const gameMessage = $('#gameMessage');
const creditMessage = $('#creditMessage');

function setMessage(el, text = '', type = '') {
  el.textContent = text;
  el.className = `message ${type}`.trim();
}

async function request(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
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

function renderPlayer(data) {
  state.player = data.player;
  $('#playerDisplay').textContent = data.player.name;
  $('#balanceDisplay').textContent = Number(data.player.balance).toLocaleString('pt-MZ');

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
        <span>Aposta <strong>${Number(bet.amount).toLocaleString('pt-MZ')}</strong></span>
        <strong class="${bet.won ? 'win' : 'loss'}">${bet.won ? `+${Number(bet.payout).toLocaleString('pt-MZ')}` : 'Não ganhou'}</strong>
      </div>
    `).join('');
  }

  playerGate.classList.add('hidden');
  gameArea.classList.remove('hidden');
}

async function loadPlayer() {
  if (!state.playerId) {
    playerGate.classList.remove('hidden');
    gameArea.classList.add('hidden');
    return;
  }
  try {
    const data = await request(`/api/players/${encodeURIComponent(state.playerId)}`);
    renderPlayer(data);
  } catch (error) {
    localStorage.removeItem('jl_player_id');
    state.playerId = '';
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
    localStorage.setItem('jl_player_id', state.playerId);
    await loadPlayer();
  } catch (error) {
    setMessage(gateMessage, error.message, 'error');
  }
});

$('#switchPlayer').addEventListener('click', () => {
  localStorage.removeItem('jl_player_id');
  state.playerId = '';
  state.player = null;
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
    setMessage(creditMessage, `Pedido de ${data.request.amount} créditos enviado. Aguarda aprovação do administrador.`, 'success');
    $('#creditNote').value = '';
  } catch (error) {
    setMessage(creditMessage, error.message, 'error');
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
      ? `Ganhou ${Number(data.bet.payout).toLocaleString('pt-MZ')}`
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
