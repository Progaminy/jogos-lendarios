'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

const html=read('aviator.html');
const js=read('aviator.js');
const manifest=JSON.parse(read('games/manifest.json'));

test('vibração foi removida completamente da interface do Aviator',()=>{
  assert.doesNotMatch(html,/aviatorVibrationToggle|haptics\.js|Ativar vibração|📳|🚫/);
  assert.doesNotMatch(js,/JLAviatorHaptics|haptics|vibrate/);
});

test('manifesto não carrega haptics',()=>{
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game);
  assert.ok(!game.assets.includes('./js/aviator/haptics.js'));
});
