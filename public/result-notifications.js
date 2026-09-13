(() => {
  const ROUNDS_BASE = 'https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-rounds';
  const $ = selector => document.querySelector(selector);
  const LAST_RESULT_KEY = 'jl_last_announced_round';
  const NOTIFY_ENABLED_KEY = 'jl_result_notifications_enabled';

  async function getGameState() {
    const response = await fetch(`${ROUNDS_BASE}/api/game-state`, {
      headers: { 'Content-Type': 'application/json' },
      cache: 'no-store'
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || 'Não foi possível consultar o resultado.');
    return data;
  }

  function ensureNotificationButton() {
    if ($('#enableResultNotifications')) return;
    const stateBar = $('#roundStateBar');
    if (!stateBar) return;

    const wrap = document.createElement('div');
    wrap.style.cssText = 'display:flex;justify-content:center;margin:10px 0 0';
    const button = document.createElement('button');
    button.id = 'enableResultNotifications';
    button.type = 'button';
    button.className = 'button ghost';
    button.style.cssText = 'min-height:42px';

    if (!('Notification' in window)) {
      button.textContent = '🔕 Notificações não suportadas';
      button.disabled = true;
    } else if (Notification.permission === 'granted') {
      button.textContent = '🔔 Avisos de resultado ativos';
    } else if (Notification.permission === 'denied') {
      button.textContent = '🔕 Avisos bloqueados no navegador';
      button.disabled = true;
    } else {
      button.textContent = '🔔 Ativar avisos de resultados';
    }

    button.addEventListener('click', async () => {
      if (!('Notification' in window)) return;
      const permission = await Notification.requestPermission();
      if (permission === 'granted') {
        localStorage.setItem(NOTIFY_ENABLED_KEY, '1');
        button.textContent = '🔔 Avisos de resultado ativos';
        showInlineNotice('Notificações ativadas. Você será avisado quando o resultado for publicado.', false);
      } else {
        button.textContent = '🔕 Avisos bloqueados no navegador';
      }
    });

    wrap.appendChild(button);
    stateBar.insertAdjacentElement('afterend', wrap);
  }

  function showInlineNotice(text, isResult = true) {
    let notice = $('#resultAnnouncement');
    if (!notice) {
      notice = document.createElement('div');
      notice.id = 'resultAnnouncement';
      notice.setAttribute('role', 'status');
      notice.setAttribute('aria-live', 'assertive');
      const numberCard = document.querySelector('.number-picker-card');
      if (numberCard) numberCard.insertAdjacentElement('beforebegin', notice);
      else document.querySelector('main')?.prepend(notice);
    }
    notice.className = 'card';
    notice.style.cssText = `margin:0 0 16px;padding:14px 16px;border:1px solid ${isResult ? 'var(--accent)' : 'var(--border)'};background:${isResult ? 'rgba(243,180,27,.12)' : 'rgba(255,255,255,.03)'};font-weight:800;text-align:center`;
    notice.textContent = text;
  }

  function notifyPublished(round) {
    const number = round.drawnNumber;
    const title = '🎉 Resultado anunciado — Jogos Lendários';
    const body = `Número sorteado: ${number}. Abra o jogo para ver o seu resultado.`;

    showInlineNotice(`🎉 Resultado publicado: número ${number}. Confira a sua aposta.`, true);
    document.title = `Resultado ${number} — Jogos Lendários`;

    if (
      'Notification' in window &&
      Notification.permission === 'granted' &&
      localStorage.getItem(NOTIFY_ENABLED_KEY) === '1'
    ) {
      const notification = new Notification(title, {
        body,
        icon: '/icon.png',
        badge: '/icon.png',
        tag: `jogos-lendarios-round-${round.id}`,
        renotify: false
      });
      notification.onclick = () => {
        window.focus();
        window.location.href = '/';
        notification.close();
      };
    }
  }

  async function pollPublishedResult() {
    try {
      const data = await getGameState();
      const round = data.round;
      if (!round || round.status !== 'published' || round.drawnNumber === null || round.drawnNumber === undefined) return;

      const lastRound = localStorage.getItem(LAST_RESULT_KEY) || '';
      if (String(round.id) === lastRound) return;

      localStorage.setItem(LAST_RESULT_KEY, String(round.id));
      notifyPublished(round);
    } catch {
      // O estado principal do jogo já trata falhas de rede.
    }
  }

  function init() {
    if (!document.querySelector('#numberGrid')) return;
    ensureNotificationButton();
    setInterval(ensureNotificationButton, 1000);
    pollPublishedResult();
    setInterval(pollPublishedResult, 4000);
  }

  init();
})();
