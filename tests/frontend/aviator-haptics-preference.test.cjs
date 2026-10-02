'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

const html=read('aviator.html');
const js=read('aviator.js');
const haptics=read('js/aviator/haptics.js');
const manifest=JSON.parse(read('games/manifest.json'));

test('Aviator tem controlo de vibração discreto, acessível e separado do som',()=>{
  assert.match(html,/id="aviatorVibrationToggle"/);
  assert.match(html,/aria-pressed="false"/);
  assert.match(html,/aria-label="Ativar vibração do Aviator"/);
  assert.match(haptics,/button\.textContent=enabled\?'📳':'🚫'/);
  assert.doesNotMatch(haptics,/📳 Vib\.|🚫 Vib\./);
});

test('vibração é compatível, persistente e desligada por padrão',()=>{
  assert.match(haptics,/STORAGE_KEY='jl_aviator_vibration_enabled'/);
  assert.match(haptics,/typeof navigatorRef\?\.vibrate==='function'/);
  assert.match(haptics,/let enabled=false/);
  assert.match(haptics,/storage\.getItem\(STORAGE_KEY\)==='1'/);
  assert.match(haptics,/storage\.setItem\(STORAGE_KEY,enabled\?'1':'0'\)/);
});

test('crash vibra somente 60 ms e uma vez por rodada',()=>{
  assert.match(haptics,/navigatorRef\.vibrate\(60\)/);
  assert.match(haptics,/terminalRoundId!==roundId/);
  assert.match(haptics,/terminalRoundId=roundId/);
  assert.match(haptics,/terminal&&!wasTerminal/);
});

test('primeiro snapshot terminal não provoca vibração retroativa',()=>{
  const initBlock=haptics.match(/if\(!initialized\)\{[\s\S]*?return;\n      \}/)?.[0]||'';
  assert.match(initBlock,/lastRoundId=roundId/);
  assert.match(initBlock,/lastStatus=status/);
  assert.match(initBlock,/terminalRoundId=roundId/);
  assert.doesNotMatch(initBlock,/vibrateCrash\(/);
});

test('vibração não existe no loop visual nem em chamadas financeiras',()=>{
  const paint=js.match(/function paintFlight\([^)]*\)[\s\S]*?\n\}/)?.[0]||'';
  const loop=js.match(/function flightPaintLoop\([^)]*\)[\s\S]*?\n\}/)?.[0]||'';
  assert.doesNotMatch(paint,/haptics|vibrate/);
  assert.doesNotMatch(loop,/haptics|vibrate/);

  assert.match(js,/haptics\?\.syncRound\(round\)/);
  assert.doesNotMatch(haptics,/JLApi\.rpc|fetch\(/);
});

test('manifesto registra módulo de haptics',()=>{
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game);
  assert.ok(game.assets.includes('./js/aviator/haptics.js'));
});
