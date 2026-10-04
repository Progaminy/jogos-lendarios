(() => {
  'use strict';

  function create({ state, els, showToast }) {
    const MASTER_VOLUME=2.35;
    const MAX_TONE_VOLUME=.22;
    const MAX_NOISE_VOLUME=.20;

    function updateSoundButton() {
      if (!els.soundToggle) return;
      els.soundToggle.textContent = state.soundEnabled ? '🔊 Som' : '🔇 Som';
      els.soundToggle.setAttribute('aria-pressed', state.soundEnabled ? 'true' : 'false');
      els.soundToggle.title = state.soundEnabled ? 'Desativar sons do Ludo' : 'Ativar sons do Ludo';
    }

    function ensureAudio() {
      if (!state.soundEnabled) return null;
      const AudioCtx = window.AudioContext || window.webkitAudioContext;
      if (!AudioCtx) return null;
      if (!state.audioCtx) state.audioCtx = new AudioCtx();
      if (state.audioCtx.state === 'suspended') state.audioCtx.resume().catch(() => {});
      return state.audioCtx;
    }

    function soundTone(freq, duration, volume = .035, delay = 0, type = 'triangle') {
      const ctx = ensureAudio();
      if (!ctx) return;
      const start = ctx.currentTime + delay;
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = type;
      osc.frequency.setValueAtTime(freq, start);
      gain.gain.setValueAtTime(.0001, start);
      const boosted=Math.min(MAX_TONE_VOLUME,Math.max(.0002,Number(volume||0)*MASTER_VOLUME));
      gain.gain.exponentialRampToValueAtTime(boosted, start + .008);
      gain.gain.exponentialRampToValueAtTime(.0001, start + duration);
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start(start);
      osc.stop(start + duration + .02);
    }

    function toggleSound() {
      state.soundEnabled = !state.soundEnabled;
      localStorage.setItem('jl_ludo_sound_enabled', state.soundEnabled ? '1' : '0');
      if (state.soundEnabled) {
        ensureAudio();
        soundTone(520, .09, .05, 0, 'triangle');
        showToast('Som do Ludo ligado.', 'success');
      } else {
        showToast('Som do Ludo desligado.');
      }
      updateSoundButton();
    }

    function playRollSound() {
      if (!state.soundEnabled) return;
      ensureAudio();
      [0, .045, .09, .135, .18, .225].forEach((d, i) => {
        soundTone(170 + (i % 3) * 45, .045, .032, d, i % 2 ? 'square' : 'triangle');
      });
    }

    function playStepSound(stepIndex) {
      if (!state.soundEnabled) return;
      soundTone(300 + (stepIndex % 2) * 55, .045, .022, 0, 'sine');
    }

    function playCaptureSound() {
      if (!state.soundEnabled) return;
      soundTone(620, .07, .07, 0, 'square');
      soundTone(310, .11, .075, .07, 'sawtooth');
    }

    function playHomeSound() {
      if (!state.soundEnabled) return;
      [440, 660, 880].forEach((f, i) => soundTone(f, .12, .055, i * .08, 'triangle'));
    }

    function noiseBurst(delay = 0, duration = .18, volume = .08) {
      const ctx = ensureAudio();
      if (!ctx) return;
      const length = Math.max(1, Math.floor(ctx.sampleRate * duration));
      const buffer = ctx.createBuffer(1, length, ctx.sampleRate);
      const data = buffer.getChannelData(0);
      for (let i = 0; i < length; i += 1) data[i] = (Math.random() * 2 - 1) * (1 - i / length);
      const src = ctx.createBufferSource();
      const gain = ctx.createGain();
      src.buffer = buffer;
      const start = ctx.currentTime + delay;
      gain.gain.setValueAtTime(Math.min(MAX_NOISE_VOLUME,Math.max(.001,Number(volume||0)*MASTER_VOLUME)), start);
      gain.gain.exponentialRampToValueAtTime(.0001, start + duration);
      src.connect(gain);
      gain.connect(ctx.destination);
      src.start(start);
    }

    function playFireworksSound() {
      if (!state.soundEnabled) return;
      [0, .22, .46, .72].forEach((d, i) => {
        soundTone(520 + i * 90, .18, .045, d, 'sine');
        soundTone(980 + i * 70, .10, .035, d + .08, 'triangle');
        noiseBurst(d + .12, .24, .10);
      });
    }

    return Object.freeze({
      updateSoundButton,
      toggleSound,
      ensureAudio,
      playRollSound,
      playStepSound,
      playCaptureSound,
      playHomeSound,
      playFireworksSound
    });
  }

  window.JLLudoSound = Object.freeze({ create });
})();