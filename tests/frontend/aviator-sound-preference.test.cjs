'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

const html=read('aviator.html');
const js=read('aviator.js');
const panel=read('js/aviator/bet-panel.js');
const sound=read('js/aviator/sound.js');
const manifest=JSON.parse(read('games/manifest.json'));

test('Aviator mantém apenas controlo de som',()=>{
  assert.match(html,/id="aviatorSoundToggle"/);
  assert.match(html,/aria-label="Ativar som do Aviator"/);
  assert.doesNotMatch(html,/aviatorVibrationToggle/);
  assert.match(sound,/button\.textContent=enabled\?'🔊':'🔇'/);
});

test('som é persistente e desligado por padrão',()=>{
  assert.match(sound,/STORAGE_KEY='jl_aviator_sound_enabled'/);
  assert.match(sound,/let enabled=false/);
  assert.match(sound,/storage\.getItem\(STORAGE_KEY\)==='1'/);
  assert.match(sound,/storage\.setItem\(STORAGE_KEY,enabled\?'1':'0'\)/);
});

test('contagem 10 a 0 toca um único bip por segundo',()=>{
  assert.match(sound,/function syncCountdown\(roundId,second\)/);
  assert.match(sound,/s<0\|\|s>10/);
  assert.match(sound,/lastCountdownSecond===whole/);
  assert.match(sound,/playCountdown\(whole\)/);
  assert.match(js,/sound\?\.syncCountdown\?\.\(round\?\.id,seconds\)/);
});

test('voo tem som contínuo cuja frequência sobe com o multiplicador',()=>{
  assert.match(sound,/function startFlight\(\)/);
  assert.match(sound,/function updateFlight\(multiplier\)/);
  assert.match(sound,/Math\.log\(m\)\/Math\.log\(500\)/);
  assert.match(sound,/setTargetAtTime\(base,now,\.09\)/);
  assert.match(js,/sound\?\.updateFlight\?\.\(m\)/);
});

test('crash para o som de voo e toca explosão',()=>{
  assert.match(sound,/function playCrash\(\)/);
  assert.match(sound,/stopFlight\(\);/);
  assert.match(sound,/tone\(210,\.22,\.045,0,'sawtooth',58\)/);
  assert.match(sound,/status==='CRASHED'\|\|status==='SETTLED'/);
});

test('aposta e cash-out não têm efeitos sonoros próprios',()=>{
  assert.doesNotMatch(sound,/playBet|playCashout/);
  assert.doesNotMatch(js,/playBet|playCashout/);
  assert.doesNotMatch(panel,/playBet|playCashout/);
});

test('som é módulo próprio e manifesto mantém apenas sound',()=>{
  const moduleAt=html.indexOf('./js/aviator/sound.js');
  const controllerAt=html.indexOf('./aviator.js');
  assert.ok(moduleAt>=0&&controllerAt>moduleAt);
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game.assets.includes('./js/aviator/sound.js'));
  assert.ok(!game.assets.includes('./js/aviator/haptics.js'));
});
