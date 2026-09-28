(() => {
  'use strict';

  function create({ state, getRoomId }) {
    let snapshotSeq = 0;
    let appliedSnapshotSeq = 0;
    let activeMove = null;
    let autoMoveTimer = null;

    function roomId() {
      try { return getRoomId?.() || null; }
      catch { return null; }
    }

    function beginSnapshot() {
      return Object.freeze({
        seq: ++snapshotSeq,
        generation: Number(state.moveGeneration) || 0,
        roomId: roomId()
      });
    }

    function canApplySnapshot(ticket) {
      if (!ticket) return false;
      if (ticket.generation !== (Number(state.moveGeneration) || 0)) return false;
      if (ticket.seq < appliedSnapshotSeq) return false;
      return true;
    }

    function markSnapshotApplied(ticket) {
      if (!canApplySnapshot(ticket)) return false;
      appliedSnapshotSeq = Math.max(appliedSnapshotSeq, ticket.seq);
      return true;
    }

    function invalidateSnapshots() {
      cancelAutoMove();
      state.moveGeneration = (Number(state.moveGeneration) || 0) + 1;
      return state.moveGeneration;
    }

    function beginMove({ roomId: moveRoomId, playerId, tokenNo, fromSteps, toSteps }) {
      invalidateSnapshots();
      activeMove = Object.freeze({
        generation: state.moveGeneration,
        roomId: moveRoomId || roomId(),
        playerId,
        tokenNo: Number(tokenNo),
        fromSteps: Number(fromSteps),
        toSteps: Number(toSteps)
      });
      return activeMove;
    }

    function isMoveCurrent(ticket) {
      if (!ticket || activeMove !== ticket) return false;
      if (ticket.generation !== (Number(state.moveGeneration) || 0)) return false;
      const currentRoom = roomId();
      return !ticket.roomId || !currentRoom || ticket.roomId === currentRoom;
    }

    function finishMove(ticket) {
      if (activeMove === ticket) activeMove = null;
    }

    function cancelAutoMove() {
      if (autoMoveTimer) clearTimeout(autoMoveTimer);
      autoMoveTimer = null;
    }

    function scheduleAutoMove(delay, fn) {
      cancelAutoMove();
      const generation = Number(state.moveGeneration) || 0;
      const scheduledRoom = roomId();

      autoMoveTimer = setTimeout(() => {
        autoMoveTimer = null;
        if (generation !== (Number(state.moveGeneration) || 0)) return;
        if (scheduledRoom && roomId() && scheduledRoom !== roomId()) return;
        fn();
      }, Math.max(0, Number(delay) || 0));
    }

    function reset() {
      cancelAutoMove();
      activeMove = null;
      snapshotSeq = 0;
      appliedSnapshotSeq = 0;
    }

    function debugState() {
      return {
        snapshotSeq,
        appliedSnapshotSeq,
        moveGeneration: Number(state.moveGeneration) || 0,
        activeMove: activeMove ? { ...activeMove } : null,
        autoMoveScheduled: Boolean(autoMoveTimer)
      };
    }

    return Object.freeze({
      beginSnapshot,
      canApplySnapshot,
      markSnapshotApplied,
      invalidateSnapshots,
      beginMove,
      isMoveCurrent,
      finishMove,
      cancelAutoMove,
      scheduleAutoMove,
      reset,
      debugState
    });
  }

  window.JLLudoMovementGuard = Object.freeze({ create });
})();