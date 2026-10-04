(() => {
  'use strict';

  let sharedState = window.__JL_LUDO_RUNTIME_STATE__ || null;

  function create() {
    if (sharedState) return sharedState;

    const token = window.JLSession?.getPlayerToken?.()
      || localStorage.getItem('jl_player_token')
      || '';

    sharedState = {
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

    window.__JL_LUDO_RUNTIME_STATE__ = sharedState;
    return sharedState;
  }

  window.JLLudoState = Object.freeze({ create });
})();
