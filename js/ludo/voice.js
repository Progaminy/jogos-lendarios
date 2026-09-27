(() => {
  'use strict';

  function create({ state, els, cfg, rpc, roomData, roomPlayers, me, showToast, ensureAudio }) {
    function stopVoiceIfRoomEnded() {
      if (!state.room || ['finished', 'cancelled'].includes(roomData()?.status)) closeVoice();
    }

    function renderVoice() {
      const available = Boolean(state.room && roomData()?.status !== 'finished' && roomData()?.status !== 'cancelled');
      if (!available) {
        closeVoice();
        if (els.voiceState) els.voiceState.textContent = 'Indisponível';
        for (const b of [els.micButton, els.micQuickButton]) {
          if (b) {
            b.disabled = true;
            b.textContent = '🎙️ Microfone indisponível';
          }
        }
        return;
      }

      const on = Boolean(state.localStream?.getAudioTracks?.().some((t) => t.readyState === 'live'));
      const connected = on && [...state.peers.values()].some((w) => w.pc.connectionState === 'connected');
      if (els.voiceState) els.voiceState.textContent = on
        ? (connected ? 'Ligado · conectado' : 'Ligado · aguardando conexão')
        : 'Desligado';

      const label = on ? '🔇 Desligar microfone' : '🎙️ Ligar microfone';
      for (const b of [els.micButton, els.micQuickButton]) {
        if (b) {
          b.disabled = false;
          b.textContent = label;
        }
      }
      startSignalPolling();
    }

    async function toggleMic() {
      if (!state.room) return;
      try {
        if (!navigator.mediaDevices?.getUserMedia) {
          throw new Error('Este navegador não disponibiliza acesso ao microfone.');
        }

        if (!state.localStream) {
          const stream = await navigator.mediaDevices.getUserMedia({
            audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
            video: false
          });
          const track = stream.getAudioTracks()[0];
          if (!track || track.readyState !== 'live') {
            stream.getTracks().forEach((t) => t.stop());
            throw new Error('O microfone não iniciou áudio ativo.');
          }

          track.enabled = true;
          track.onended = () => {
            if (state.localStream === stream) {
              state.localStream = null;
              state.micMuted = true;
              renderVoice();
              showToast('O acesso ao microfone foi interrompido.', 'error');
            }
          };

          state.localStream = stream;
          state.micMuted = false;
          for (const p of roomPlayers()) {
            if (p.player_id !== me()) ensurePeer(p.player_id, true);
          }
          showToast('Microfone ligado.', 'success');
        } else {
          state.localStream.getTracks().forEach((t) => t.stop());
          state.localStream = null;
          state.micMuted = true;
          for (const wrap of state.peers.values()) {
            for (const sender of wrap.pc.getSenders()) {
              if (sender.track?.kind === 'audio') sender.replaceTrack(null).catch(() => {});
            }
          }
          showToast('Microfone desligado.');
        }
        renderVoice();
      } catch (error) {
        showToast(`Microfone: ${error.message}`, 'error');
        renderVoice();
      }
    }

    function startSignalPolling() {
      if (!state.room) return;
      state.signalPolling = true;
      if (window.JLLudoSync?.kick) {
        window.JLLudoSync.kick('ludo-voice');
        return;
      }
      if (state.signalTimer) return;
      state.signalTimer = setInterval(pullSignals, 1000);
      pullSignals();
    }

    function stopSignalPolling() {
      state.signalPolling = false;
      if (state.signalTimer) clearInterval(state.signalTimer);
      state.signalTimer = null;
    }

    async function sendSignal(to, type, payload) {
      try {
        await rpc('jl_ludo_signal_send', {
          p_token: state.token,
          p_room: roomData().id,
          p_to_player: to,
          p_signal_type: type,
          p_payload: payload
        });
      } catch (error) {
        console.warn('signal', error.message);
      }
    }

    function voiceIceServers() {
      const configured = Array.isArray(cfg.ludoIceServers) ? cfg.ludoIceServers.filter(Boolean) : [];
      if (configured.length) return configured;
      return [
        { urls: 'stun:stun.l.google.com:19302' },
        { urls: 'stun:stun1.l.google.com:19302' },
        { urls: 'stun:stun2.l.google.com:19302' }
      ];
    }

    function ensurePeer(peerId, addTracks = false) {
      let wrap = state.peers.get(peerId);
      if (wrap) {
        if (addTracks && state.localStream) attachTracks(wrap.pc);
        return wrap;
      }

      const pc = new RTCPeerConnection({ iceServers: voiceIceServers() });
      wrap = {
        pc,
        makingOffer: false,
        ignoreOffer: false,
        polite: String(me()) > String(peerId),
        pendingIce: [],
        restarted: false
      };
      state.peers.set(peerId, wrap);

      pc.onicecandidate = (event) => {
        if (event.candidate) sendSignal(peerId, 'ice', event.candidate.toJSON());
      };

      pc.ontrack = (event) => {
        let audio = document.getElementById('audio-' + peerId);
        if (!audio) {
          audio = document.createElement('audio');
          audio.id = 'audio-' + peerId;
          audio.autoplay = true;
          audio.playsInline = true;
          els.remoteAudio.appendChild(audio);
        }
        audio.srcObject = event.streams[0];
        audio.play().then(() => {
          audio.controls = false;
        }).catch(() => {
          audio.controls = true;
          showToast('Áudio recebido. Toque no controlo de áudio para ouvir.', 'success');
        });
      };

      pc.onconnectionstatechange = async () => {
        renderVoice();
        if (pc.connectionState === 'connected') {
          wrap.restarted = false;
          return;
        }
        if (pc.connectionState === 'failed' && !wrap.restarted) {
          wrap.restarted = true;
          try {
            pc.restartIce?.();
            wrap.makingOffer = true;
            await pc.setLocalDescription(await pc.createOffer({ iceRestart: true }));
            await sendSignal(peerId, 'offer', pc.localDescription);
          } catch (error) {
            console.warn('voice restart', error);
          } finally {
            wrap.makingOffer = false;
          }
        }
      };

      pc.onnegotiationneeded = async () => {
        try {
          wrap.makingOffer = true;
          await pc.setLocalDescription(await pc.createOffer());
          await sendSignal(peerId, 'offer', pc.localDescription);
        } catch (error) {
          console.warn('voice negotiate', error);
        } finally {
          wrap.makingOffer = false;
        }
      };

      if (addTracks && state.localStream) attachTracks(pc);
      return wrap;
    }

    function attachTracks(pc) {
      if (!state.localStream) return;
      for (const track of state.localStream.getTracks()) {
        const sender = pc.getSenders().find((s) => s.track?.kind === track.kind);
        if (sender) {
          if (sender.track !== track) sender.replaceTrack(track).catch(() => {});
        } else {
          pc.addTrack(track, state.localStream);
        }
      }
    }

    async function flushPendingIce(wrap) {
      if (!wrap?.pc?.remoteDescription) return;
      while (wrap.pendingIce.length) {
        const candidate = wrap.pendingIce.shift();
        try {
          await wrap.pc.addIceCandidate(new RTCIceCandidate(candidate));
        } catch (error) {
          if (!wrap.ignoreOffer) console.warn('ice flush', error);
        }
      }
    }

    async function pullSignals() {
      if (!state.room) return;
      try {
        const rows = await rpc('jl_ludo_signal_pull', {
          p_token: state.token,
          p_room: roomData().id,
          p_after_id: state.lastSignalId
        });
        for (const signal of rows) {
          state.lastSignalId = Math.max(state.lastSignalId, Number(signal.id));
          await handleSignal(signal);
        }
      } catch (error) {
        console.warn('pull signal', error.message);
      }
    }

    async function handleSignal(signal) {
      const wrap = ensurePeer(signal.from_player_id, Boolean(state.localStream));
      const pc = wrap.pc;
      try {
        if (signal.signal_type === 'offer') {
          const desc = new RTCSessionDescription(signal.payload);
          const collision = wrap.makingOffer || pc.signalingState !== 'stable';
          wrap.ignoreOffer = !wrap.polite && collision;
          if (wrap.ignoreOffer) return;

          if (collision && wrap.polite && pc.signalingState !== 'stable') {
            try { await pc.setLocalDescription({ type: 'rollback' }); } catch {}
          }

          await pc.setRemoteDescription(desc);
          await flushPendingIce(wrap);
          if (state.localStream) attachTracks(pc);
          await pc.setLocalDescription(await pc.createAnswer());
          await sendSignal(signal.from_player_id, 'answer', pc.localDescription);
        } else if (signal.signal_type === 'answer') {
          if (pc.signalingState === 'have-local-offer') {
            await pc.setRemoteDescription(new RTCSessionDescription(signal.payload));
            await flushPendingIce(wrap);
          }
        } else if (signal.signal_type === 'ice') {
          if (!pc.remoteDescription) wrap.pendingIce.push(signal.payload);
          else await pc.addIceCandidate(new RTCIceCandidate(signal.payload));
        }
      } catch (error) {
        if (!wrap.ignoreOffer) console.warn('handle signal', error);
      }
    }

    function closeVoice() {
      stopSignalPolling();
      for (const wrap of state.peers.values()) wrap.pc.close();
      state.peers.clear();
      if (state.localStream) state.localStream.getTracks().forEach((t) => t.stop());
      state.localStream = null;
      state.micMuted = true;
      state.lastSignalId = 0;
      if (els.remoteAudio) els.remoteAudio.innerHTML = '';
    }

    function unlockMediaAudio() {
      if (state.soundEnabled) ensureAudio();
      for (const audio of els.remoteAudio?.querySelectorAll?.('audio') || []) {
        if (audio.srcObject && audio.paused) audio.play().catch(() => {});
      }
    }

    return Object.freeze({
      stopVoiceIfRoomEnded,
      renderVoice,
      toggleMic,
      pullSignals,
      closeVoice,
      unlockMediaAudio
    });
  }

  window.JLLudoVoice = Object.freeze({ create });
})();