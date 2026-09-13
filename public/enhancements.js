(() => {
  const API_BASE = 'https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-api';
  const ROUNDS_BASE = 'https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-rounds';

  const $ = selector => document.querySelector(selector);

  function adminToken() {
    return sessionStorage.getItem('jl_admin_token') || '';
  }

  async function fetchJson(base, path, options = {}) {
    const token = adminToken();
    const response = await fetch(`${base}${path}`, {
      ...options,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(options.headers || {})
      }
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || 'Não foi possível concluir o pedido.');
    return data;
  }

  function localDateTimeValue(date) {
    const pad = n => String(n).padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  function ensureExactCloseControl() {
    const card = $('#roundControlCard');
    const oldInput = $('#roundMinutes');
    if (!card || !oldInput || $('#roundCloseAt')) return;

    const oldLabel = oldInput.closest('label');
    if (!oldLabel) return;

    const defaultClose = new Date(Date.now() + 5 * 60 * 1000);
    oldLabel.innerHTML = `
      Hora de encerramento
      <input id="roundCloseAt" type="datetime-local" required>
      <small style="display:block;color:var(--muted);margin-top:6px">O público verá a contagem regressiva até este horário.</small>
    `;
    $('#roundCloseAt').value = localDateTimeValue(defaultClose);
  }

  function ensureWithdrawalAlert() {
    const dashboard = $('#dashboard');
    if (!dashboard || $('#withdrawalAlert')) return;

    const header = dashboard.querySelector('.admin-header');
    const alert = document.createElement('div');
    alert.id = 'withdrawalAlert';
    alert.className = 'card hidden';
    alert.style.cssText = 'margin:0 0 18px;padding:14px 16px;border:1px solid #f3b41b;background:rgba(243,180,27,.12);font-weight:800';
    alert.setAttribute('role', 'status');
    alert.setAttribute('aria-live', 'polite');
    header?.insertAdjacentElement('afterend', alert);

    const actions = header?.querySelector('.actions');
    if (actions && !$('#enableAdminNotifications')) {
      const button = document.createElement('button');
      button.id = 'enableAdminNotifications';
      button.type = 'button';
      button.className = 'button ghost';
      button.textContent = 'Ativar notificações';
      actions.prepend(button);
      button.addEventListener('click', async () => {
        if (!('Notification' in window)) {
          button.textContent = 'Navegador sem notificações';
          button.disabled = true;
          return;
        }
        const permission = await Notification.requestPermission();
        button.textContent = permission === 'granted' ? 'Notificações ativas' : 'Notificações bloqueadas';
      });
    }
  }

  let lastPendingWithdrawals = Number(sessionStorage.getItem('jl_pending_withdrawals_seen') || 0);

  async function pollWithdrawals() {
    if (!$('#dashboard') || !adminToken()) return;
    try {
      const data = await fetchJson(API_BASE, '/api/admin/overview');
      const count = Number(data.stats?.pendingWithdrawals || 0);
      ensureWithdrawalAlert();
      const alert = $('#withdrawalAlert');

      if (count > 0) {
        alert?.classList.remove('hidden');
        if (alert) {
          alert.textContent = `🔔 ${count} pedido${count === 1 ? '' : 's'} de levantamento aguardando autorização.`;
        }
        document.title = `(${count}) Administração — Jogos Lendários`;

        if (
          count > lastPendingWithdrawals &&
          'Notification' in window &&
          Notification.permission === 'granted'
        ) {
          new Notification('Novo pedido de levantamento', {
            body: `${count} pedido${count === 1 ? '' : 's'} aguardando autorização no Jogos Lendários.`
          });
        }
      } else {
        alert?.classList.add('hidden');
        document.title = 'Administração — Jogos Lendários';
      }

      lastPendingWithdrawals = count;
      sessionStorage.setItem('jl_pending_withdrawals_seen', String(count));
    } catch {
      // O painel principal já apresenta erros de sessão/API.
    }
  }

  async function openRoundAtExactTime(event) {
    const button = event.target.closest('#openRound');
    if (!button) return;

    ensureExactCloseControl();
    const input = $('#roundCloseAt');
    if (!input) return;

    event.preventDefault();
    event.stopImmediatePropagation();
    event.stopPropagation();

    const value = input.value;
    if (!value) {
      const msg = $('#adminMessage');
      if (msg) {
        msg.textContent = 'Defina a hora de encerramento.';
        msg.className = 'message error';
      }
      return;
    }

    const closesAt = new Date(value);
    if (Number.isNaN(closesAt.getTime()) || closesAt.getTime() <= Date.now()) {
      const msg = $('#adminMessage');
      if (msg) {
        msg.textContent = 'A hora de encerramento deve estar no futuro.';
        msg.className = 'message error';
      }
      return;
    }

    button.disabled = true;
    try {
      await fetchJson(ROUNDS_BASE, '/api/admin/rounds/open', {
        method: 'POST',
        body: JSON.stringify({ closesAt: closesAt.toISOString() })
      });
      const msg = $('#adminMessage');
      if (msg) {
        msg.textContent = `Jogo aberto até ${closesAt.toLocaleString('pt-MZ')}.`;
        msg.className = 'message success';
      }
      setTimeout(() => location.reload(), 500);
    } catch (error) {
      const msg = $('#adminMessage');
      if (msg) {
        msg.textContent = error.message;
        msg.className = 'message error';
      }
      button.disabled = false;
    }
  }

  async function interceptWithdrawal(event) {
    const form = event.target.closest('#withdrawalForm');
    if (!form) return;

    event.preventDefault();
    event.stopImmediatePropagation();
    event.stopPropagation();

    const playerId = localStorage.getItem('jl_player_id') || '';
    const token = localStorage.getItem('jl_player_token') || '';
    const amount = Number($('#withdrawalAmount')?.value);
    const message = $('#withdrawalMessage');

    if (!playerId || !token) return;
    if (!Number.isFinite(amount) || amount < 1) {
      if (message) {
        message.textContent = 'Informe um valor válido.';
        message.className = 'message error';
      }
      return;
    }

    if (message) {
      message.textContent = 'Enviando pedido...';
      message.className = 'message';
    }

    try {
      const response = await fetch(`${API_BASE}/api/withdrawals`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Player-Token': token
        },
        body: JSON.stringify({ playerId, amount })
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Não foi possível enviar o pedido.');

      const request = data.request || {};
      if (request.status === 'rejected' && request.reason === 'insufficient_balance') {
        if (message) {
          message.textContent = `Pedido rejeitado automaticamente: saldo disponível insuficiente (${Number(request.availableBalance || 0).toLocaleString('pt-MZ')} MTS disponíveis).`;
          message.className = 'message error';
        }
      } else {
        if (message) {
          message.textContent = `Pedido de ${amount.toLocaleString('pt-MZ')} MTS ficou pendente e o administrador foi notificado.`;
          message.className = 'message success';
        }
      }

      $('#refreshPlayer')?.click();
    } catch (error) {
      if (message) {
        message.textContent = error.message;
        message.className = 'message error';
      }
    }
  }

  function initAdminEnhancements() {
    if (!$('#adminLoginForm')) return;

    const observer = new MutationObserver(() => {
      ensureExactCloseControl();
      ensureWithdrawalAlert();
    });
    observer.observe(document.body, { childList: true, subtree: true });

    document.addEventListener('click', openRoundAtExactTime, true);
    setInterval(() => {
      ensureExactCloseControl();
      ensureWithdrawalAlert();
      pollWithdrawals();
    }, 3000);
    pollWithdrawals();
  }

  function initPlayerEnhancements() {
    if (!$('#withdrawalForm')) return;
    document.addEventListener('submit', interceptWithdrawal, true);
  }

  initAdminEnhancements();
  initPlayerEnhancements();
})();
