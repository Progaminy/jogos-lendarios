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

  function loadActiveRoomRecovery() {
    if (document.getElementById('jlLudoActiveRoomRecovery')) return;
    const script = document.createElement('script');
    script.id = 'jlLudoActiveRoomRecovery';
    script.src = './js/ludo/active-room-recovery.js?v=20261004-2';
    script.async = true;
    document.head.appendChild(script);
  }

  window.JLLudoState = Object.freeze({ create });
  loadActiveRoomRecovery();
})();