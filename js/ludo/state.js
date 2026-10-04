(() => {
  'use strict';

  function create() {
    const token = window.JLSession?.getPlayerToken?.()
      || localStorage.getItem('jl_player_token')
      || '';

    return {
      token,
      status: null,
      room: null,
      clockTimer: null,
      signalTimer: null,
      signalPolling: false,
      lastSignalId: 0,
      localStream: null,
      micMuted: true,
      opponentMuted: false,
      peers: new Map(),
      busy: false,
      animating: false,
      soundEnabled: localStorage.getItem('jl_ludo_sound_enabled') !== '0',
      audioCtx: null,
      rulesFormDirty: false,
      rulesFormVersion: null,
      rulesDeclinedVersion: null,
      lastFxEventId: 0,
      autoMoveKey: null,
      lastDirectInviteCount: 0,
      moveGeneration: 0,
      diceRolling: false,
      diceRollSerial: 0,
      lastDiceValue: null,
      lastDiceRoomId: null
    };
  }

  // O recovery da sala é carregado explicitamente pelo HTML.
  // Não o injetar aqui: uma cópia antiga pode vencer a corrida de boot e
  // bloquear a versão atual através do guard window.__JL_LUDO_ACTIVE_ROOM_RECOVERY__.
  window.JLLudoState = Object.freeze({ create });
})();
