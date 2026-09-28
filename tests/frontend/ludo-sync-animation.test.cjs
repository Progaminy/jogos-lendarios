'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

global.window = {};
global.CSS = { escape: (value) => String(value) };

function load(path) {
  vm.runInThisContext(fs.readFileSync(path, 'utf8'), { filename: path });
}

load('js/ludo/movement-guard.js');
load('js/ludo/room-state.js');
load('js/ludo/animation.js');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test('3G lento: polling iniciado antes da jogada não pode regressar o peão', async () => {
  const state = { moveGeneration: 0 };
  const guard = window.JLLudoMovementGuard.create({
    state,
    getRoomId: () => 'room-a'
  });

  const oldSnapshot = guard.beginSnapshot();
  const delayed = sleep(35).then(() => guard.canApplySnapshot(oldSnapshot));

  await sleep(5);
  const move = guard.beginMove({
    roomId: 'room-a',
    playerId: 'p1',
    tokenNo: 1,
    fromSteps: 4,
    toSteps: 9
  });
  guard.finishMove(move);

  assert.equal(await delayed, false);
});

test('3G lento: polling iniciado antes do lançamento não pode restaurar uma fase antiga', () => {
  const state = { moveGeneration: 0 };
  const guard = window.JLLudoMovementGuard.create({
    state,
    getRoomId: () => 'room-roll'
  });

  const staleBeforeRoll = guard.beginSnapshot();
  guard.invalidateSnapshots();

  assert.equal(guard.canApplySnapshot(staleBeforeRoll), false);
  const freshAfterRoll = guard.beginSnapshot();
  assert.equal(guard.canApplySnapshot(freshAfterRoll), true);
});

test('sincronização: resposta mais velha não sobrescreve a mais nova', () => {
  const state = { moveGeneration: 0 };
  const guard = window.JLLudoMovementGuard.create({
    state,
    getRoomId: () => 'room-b'
  });

  const older = guard.beginSnapshot();
  const newer = guard.beginSnapshot();

  assert.equal(guard.markSnapshotApplied(newer), true);
  assert.equal(guard.canApplySnapshot(older), false);
});

test('retry automático antigo é cancelado por uma nova jogada', async () => {
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
  guard.finishMove(move);
  assert.equal(fired, 0);
});

test('room_state incremental pede apenas eventos/chat posteriores e preserva janela de 50', async () => {
  const calls = [];
  window.JLApi = {
    rpc: async (name, args) => {
      calls.push({ name, args });
      if (name === 'jl_ludo_room_delta') {
        return {
          events: [{ id: 53, event_type: 'turn_started' }],
          chat: [{ id: 82, message: 'novo' }],
          payouts: []
        };
      }
      throw new Error('RPC inesperada');
    }
  };

  const api = window.JLLudoRoomState.create(() => 'test-token');
  const previous = {
    room: { id: 'room-d', status: 'playing' },
    events: Array.from({ length: 50 }, (_, i) => ({ id: i + 3 })),
    chat: Array.from({ length: 50 }, (_, i) => ({ id: i + 32 })),
    payouts: []
  };
  const base = { room: { id: 'room-d', status: 'playing' } };

  const result = await api.attachExtras(base, previous);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].args.p_after_event, 52);
  assert.equal(calls[0].args.p_after_chat, 81);
  assert.equal(calls[0].args.p_include_payouts, false);
  assert.equal(result.events.length, 50);
  assert.equal(result.events.at(-1).id, 53);
  assert.equal(result.chat.length, 50);
  assert.equal(result.chat.at(-1).id, 82);
});

test('payouts só são solicitados quando a sala terminou', async () => {
  let includePayouts = null;
  window.JLApi = {
    rpc: async (_name, args) => {
      includePayouts = args.p_include_payouts;
      return { events: [], chat: [], payouts: [{ player_id: 'p1', net: 20 }] };
    }
  };

  const api = window.JLLudoRoomState.create(() => 'test-token');
  const result = await api.attachExtras({ room: { id: 'room-e', status: 'finished' } }, null);

  assert.equal(includePayouts, true);
  assert.equal(result.payouts.length, 1);
});

test('animação detecta apenas movimento para frente e não cria vai-e-vem', () => {
  const animation = window.JLLudoAnimation.create({
    els: {},
    path: [],
    start: {},
    home: {},
    base: {},
    finishCell: {},
    trackLastStep: 50,
    homeFirstStep: 51,
    homeLastStep: 55,
    finishStep: 56,
    stepMs: 0,
    playStepSound: () => {}
  });

  const forward = animation.detectForwardMove(
    { tokens: [{ player_id: 'p1', token_no: 1, steps: 4 }] },
    {
      tokens: [{ player_id: 'p1', token_no: 1, steps: 9 }],
      players: [{ player_id: 'p1', color: 'red' }]
    }
  );
  assert.deepEqual(forward, {
    playerId: 'p1',
    tokenNo: 1,
    color: 'red',
    fromSteps: 4,
    toSteps: 9
  });

  const backwards = animation.detectForwardMove(
    { tokens: [{ player_id: 'p1', token_no: 1, steps: 9 }] },
    {
      tokens: [{ player_id: 'p1', token_no: 1, steps: 4 }],
      players: [{ player_id: 'p1', color: 'red' }]
    }
  );
  assert.equal(backwards, null);
});

test('lançamento invalida snapshots antigos e recupera o estado do servidor em conflito', () => {
  const source = fs.readFileSync('ludo.js', 'utf8');
  assert.match(source, /movementGuard\.invalidateSnapshots\(\);[\s\S]{0,1200}jl_ludo_roll/);
  assert.match(source, /recoverAuthoritativeRoom\(roomId\)/);
  assert.match(source, /Não é hora de lançar o dado\|Tempo da jogada expirou/);
});

test('triângulo final mantém uma coordenada própria por cor', () => {
  const source = fs.readFileSync('ludo.js', 'utf8');
  assert.match(
    source,
    /const FINISH_CELL=\{red:\[7,6\],green:\[6,7\],yellow:\[7,8\],blue:\[8,7\]\}/
  );
});
