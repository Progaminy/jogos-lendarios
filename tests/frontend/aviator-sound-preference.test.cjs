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

test('voo usa whoosh eletrônico crescente e não som de motor convencional',()=>{
  assert.match(sound,/function startFlight\(\)/);
  assert.match(sound,/function updateFlight\(multiplier\)/);
  assert.match(sound,/Math\.log\(m\)\/Math\.log\(500\)/);
  assert.match(sound,/const whoosh=ctx\.createBufferSource\(\)/);
  assert.match(sound,/noiseBuffer=ctx\.createBuffer/);
  assert.match(sound,/whooshFilter\.type='bandpass'/);
  assert.match(sound,/rise\.type='sine'/);
  assert.match(sound,/edge\.type='triangle'/);
  assert.match(sound,/rise\.frequency\.setValueAtTime\(185/);
  assert.match(sound,/edge\.frequency\.setValueAtTime\(370/);
  assert.match(sound,/const tension=Math\.pow\(progress,\.62\)/);
  assert.match(sound,/whooshGain\.gain\.setTargetAtTime/);
  assert.match(sound,/whooshFilter\.frequency\.setTargetAtTime/);
  assert.match(sound,/createDynamicsCompressor\(\)/);
  assert.doesNotMatch(sound,/binaural|subliminal|hypnot/i);
  assert.match(js,/sound\?\.updateFlight\?\.\(m\)/);
});

test('crash para o som de voo e toca impacto forte sem aspereza',()=>{
  assert.match(sound,/function playCrash\(\)/);
  assert.match(sound,/stopFlight\(\);/);
  assert.match(sound,/linearRampToValueAtTime\(\.0001,now\+\.015\)/);
  assert.match(sound,/const duration=\.14/);
  assert.match(sound,/tone\(145,\.16,\.060,0,'sine',58\)/);
  assert.doesNotMatch(sound,/sawtooth|square/);
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


test('som persistido após refresh desbloqueia no primeiro gesto sem inverter para desligado',()=>{
  assert.match(sound,/async function activateAudio\(\)/);
  assert.match(sound,/if\(ctx\.state!=='running'\)\{/);
  assert.match(sound,/await ctx\.resume\(\)/);
  assert.match(sound,/async function handleButtonClick\(event\)/);
  assert.match(sound,/if\(enabled&&!audioRunning\(\)\)/);
  assert.match(sound,/await activateAudio\(\)/);
  assert.match(sound,/button\?\.addEventListener\('click',handleButtonClick\)/);
  assert.match(sound,/if\(button&&event\?\.target&&button\.contains\?\.\(event\.target\)\)return/);
  assert.doesNotMatch(sound,/button\?\.addEventListener\('click',toggle\)/);
});
