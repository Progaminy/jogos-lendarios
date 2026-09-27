(() => {
  'use strict';

  function create({ els, setMessage }) {
    function open(mode = 'register') {
      els.authModal.classList.remove('hidden');
      document.body.classList.add('modal-open');
      switchMode(mode);
      setMessage(els.authMessage);
    }

    function close() {
      els.authModal.classList.add('hidden');
      document.body.classList.remove('modal-open');
    }

    function switchMode(mode) {
      const register = mode === 'register';
      els.registerTab.classList.toggle('active', register);
      els.loginTab.classList.toggle('active', !register);
      els.registerForm.classList.toggle('hidden', !register);
      els.loginForm.classList.toggle('hidden', register);
      setMessage(els.authMessage);
    }

    async function validateInviteCode() {
      if (!els.registerInviteCode) return true;
      const code = els.registerInviteCode.value.trim().toUpperCase();
      els.registerInviteCode.value = code;

      if (!code) {
        if (els.registerInviteStatus) {
          els.registerInviteStatus.textContent = '';
          els.registerInviteStatus.style.color = '';
        }
        return true;
      }

      if (els.registerInviteStatus) {
        els.registerInviteStatus.textContent = 'A validar código…';
        els.registerInviteStatus.style.color = '';
      }

      try {
        const result = await window.JLApi.rpc('jl_validate_invite_code', { p_code: code });
        if (!result?.valid) {
          if (els.registerInviteStatus) {
            els.registerInviteStatus.textContent = 'Código de convite inválido ou inativo.';
            els.registerInviteStatus.style.color = '#ff8994';
          }
          return false;
        }
        if (els.registerInviteStatus) {
          els.registerInviteStatus.textContent = 'Código válido · ' + (result.influencer || 'Influenciador');
          els.registerInviteStatus.style.color = '#8df1bb';
        }
        return true;
      } catch (error) {
        if (els.registerInviteStatus) {
          els.registerInviteStatus.textContent = error.message || 'Não foi possível validar o código.';
          els.registerInviteStatus.style.color = '#ff8994';
        }
        return false;
      }
    }

    return Object.freeze({ open, close, switchMode, validateInviteCode });
  }

  window.JLPlayerAuthUI = Object.freeze({ create });
})();