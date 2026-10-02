'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

const html=read('aviator.html');
const js=read('aviator.js');
const sound=read('js/aviator/sound.js');
const manifest=JSON.parse(read('games/manifest.json'));

test('Aviator tem controlo de som discreto e acessível',()=>{
  assert.match(html,/id="aviatorSoundToggle"/);
  assert.match(html,/aria-pressed="false"/);
  assert.match(html,/aria-label="Ativar som do Aviator"/);
  assert.match(sound,/button\.textContent=enabled\?'🔊':'🔇'/);
  assert.doesNotMatch(sound,/🔊 Som|🔇 Som/);
});

test('preferência de som é persistente e silenciosa por padrão',()=>{
  assert.match(sound,/STORAGE_KEY='jl_aviator_sound_enabled'/);
  assert.match(sound,/enabled=storage\.getItem\(STORAGE_KEY\)==='1'/);
  assert.match(sound,/storage\.setItem\(STORAGE_KEY,enabled\?'1':'0'\)/);
  assert.match(sound,/let enabled=false/);
});

test('som é módulo próprio carregado antes do orquestrador',()=>{
  const moduleAt=html.indexOf('./js/aviator/sound.js');
  const controllerAt=html.indexOf('./aviator.js');
  assert.ok(moduleAt>=0);
  assert.ok(controllerAt>moduleAt);
  assert.match(js,/JLAviatorSound\?\.create/);
});

test('eventos de rodada são deduplicados e não tocam por frame',()=>{
  assert.match(sound,/lastRoundId===roundId&&lastStatus===status/);
  assert.match(sound,/status==='LOCKED'/);
  assert.match(sound,/status==='FLYING'/);
  assert.match(sound,/status==='CRASHED'\|\|status==='SETTLED'/);

  const paint=js.match(/function paintFlight\([^)]*\)[\s\S]*?\n\}/)?.[0]||'';
  const loop=js.match(/function flightPaintLoop\([^)]*\)[\s\S]*?\n\}/)?.[0]||'';
  assert.doesNotMatch(paint,/sound\.|AudioContext|tone\(/);
  assert.doesNotMatch(loop,/sound\.|AudioContext|tone\(/);
});

test('cash-out só toca depois da confirmação do servidor',()=>{
  const block=js.match(/\$\('#cashoutBtn'\)\.addEventListener\('click',[\s\S]*?\n\}\);/)?.[0]||'';
  const rpcAt=block.indexOf('requestFinancialCashout');
  const soundAt=block.indexOf('sound?.playCashout()');
  assert.ok(rpcAt>=0);
  assert.ok(soundAt>rpcAt);
});

test('aposta só toca após resposta de placeBet',()=>{
  const block=js.match(/\$\('#aviatorBetForm'\)\.addEventListener\('submit',[\s\S]*?\n\}\);/)?.[0]||'';
  const rpcAt=block.indexOf('financial.placeBet');
  const soundAt=block.indexOf('sound?.playBet()');
  assert.ok(rpcAt>=0);
  assert.ok(soundAt>rpcAt);
});

test('manifesto registra módulo de som do Aviator',()=>{
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game);
  assert.ok(game.assets.includes('./js/aviator/sound.js'));
});
