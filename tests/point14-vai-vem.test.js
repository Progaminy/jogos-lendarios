(() => {
  'use strict';

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  function assert(condition, message) {
    if (!condition) throw new Error(message);
  }

  async function runPoint14Tests() {
    const results = [];

    // 1. Simula 3G lento: polling começa antes da jogada e responde depois.
    {
      const state = { moveGeneration: 0 };
      let currentRoom = 'room-a';
      const guard = window.JLLudoMovementGuard.create({
        state,
        getRoomId: () => currentRoom
      });

      const slowSnapshot = guard.beginSnapshot();
      const delayedOldResponse = sleep(40).then(() => guard.canApplySnapshot(slowSnapshot));

      await sleep(5);
      const move = guard.beginMove({
        roomId: currentRoom,
        playerId: 'p1',
        tokenNo: 1,
        fromSteps: 4,
        toSteps: 9
      });
      assert(guard.isMoveCurrent(move), 'A jogada atual deixou de ser reconhecida.');
      guard.finishMove(move);

      const accepted = await delayedOldResponse;
      assert(accepted === false, 'Resposta antiga de polling foi aceite após uma jogada.');
      results.push('3G lento: resposta pré-jogada descartada');
    }

    // 2. Duas respostas concorrentes: a mais nova chega primeiro.
    {
      const state = { moveGeneration: 0 };
      const guard = window.JLLudoMovementGuard.create({
        state,
        getRoomId: () => 'room-b'
      });

      const older = guard.beginSnapshot();
      const newer = guard.beginSnapshot();
      assert(guard.markSnapshotApplied(newer), 'Snapshot mais novo não foi aplicado.');
      assert(!guard.canApplySnapshot(older), 'Snapshot mais antigo sobrescreveria o novo.');
      results.push('concorrência: resposta fora de ordem descartada');
    }

    // 3. Retry automático agendado não pode sobreviver a uma nova jogada.
    {
      const state = { moveGeneration: 0 };
      const guard = window.JLLudoMovementGuard.create({
        state,
        getRoomId: () => 'room-c'
      });

      let fired = 0;
      guard.scheduleAutoMove(25, () => { fired += 1; });
      await sleep(5);
      const move = guard.beginMove({
        roomId: 'room-c',
        playerId: 'p1',
        tokenNo: 2,
        fromSteps: 10,
        toSteps: 14
      });
      await sleep(40);
      assert(fired === 0, 'Retry antigo disparou durante/depois de uma nova jogada.');
      guard.finishMove(move);
      results.push('retry antigo: cancelado por nova jogada');
    }

    // 4. Refresh: a proteção transitória não persiste no navegador novo.
    {
      const oldState = { moveGeneration: 0 };
      const oldGuard = window.JLLudoMovementGuard.create({
        state: oldState,
        getRoomId: () => 'room-d'
      });
      oldGuard.beginMove({
        roomId: 'room-d',
        playerId: 'p1',
        tokenNo: 3,
        fromSteps: 20,
        toSteps: 25
      });

      const refreshedState = { moveGeneration: 0 };
      const refreshedGuard = window.JLLudoMovementGuard.create({
        state: refreshedState,
        getRoomId: () => 'room-d'
      });
      const authoritative = refreshedGuard.beginSnapshot();
      assert(refreshedGuard.markSnapshotApplied(authoritative), 'Refresh não aceitou o estado autoritativo.');
      assert(refreshedGuard.debugState().activeMove === null, 'Refresh herdou movimento otimista antigo.');
      results.push('refresh durante movimento: volta ao estado autoritativo');
    }

    // 5. Observador de outra sessão: novo estado aplica, antigo não regressa depois.
    {
      const observerState = { moveGeneration: 0 };
      const observer = window.JLLudoMovementGuard.create({
        state: observerState,
        getRoomId: () => 'room-e'
      });

      const beforeRemoteMove = observer.beginSnapshot();
      const afterRemoteMove = observer.beginSnapshot();
      assert(observer.markSnapshotApplied(afterRemoteMove), 'Observador não aceitou estado mais novo.');
      await sleep(10);
      assert(!observer.canApplySnapshot(beforeRemoteMove), 'Observador regressaria ao estado anterior.');
      results.push('dois clientes: observador não regressa após movimento remoto');
    }

    return { ok: true, count: results.length, results };
  }

  window.runPoint14Tests = runPoint14Tests;
})();