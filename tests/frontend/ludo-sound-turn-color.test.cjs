'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

test('som do Ludo usa ganho mestre mais alto com limite seguro',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../js/ludo/sound.js'),'utf8');
  assert.match(js,/MASTER_VOLUME=2\.35/);
  assert.match(js,/MAX_TONE_VOLUME=\.22/);
  assert.match(js,/volume\|\|0\)\*MASTER_VOLUME/);
});

test('efeitos de eventos remotos são processados na mesma atualização Realtime',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../ludo.js'),'utf8');
  assert.match(js,/renderAll\(\);[\s\S]{0,220}processGameEffects\(nextRoom\)/);
});

test('lacre da vez segue a cor do jogador no Ludo e no espectador',()=>{
  const css=fs.readFileSync(path.join(__dirname,'../../ludo.css'),'utf8');
  const adminCss=fs.readFileSync(path.join(__dirname,'../../admin-ludo-spectator.css'),'utf8');
  for(const color of ['red','green','yellow','blue']){
    assert.match(css,new RegExp('player-card\\.current\\.'+color));
    assert.match(adminCss,new RegExp('ludo-watch-player\\.current:has\\(\\.ludo-watch-dot\\.'+color+'\\)'));
  }
});
