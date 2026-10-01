'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

test('Nova partida oferece 1, 2, 3 ou 4 peoes e inicia em 4',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../ludo.html'),'utf8');
  assert.match(html,/id="createPawnCount"/);
  for(const n of [1,2,3,4]){
    assert.match(html,new RegExp('data-select-id="createPawnCount"[\\s\\S]{0,900}data-player-count="'+n+'"'));
  }
  assert.match(html,/id="createPawnCount"[^>]*>[\s\S]*<option value="4" selected>/);
});

test('criacao da sala envia pawn_count escolhido ao servidor',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../ludo.js'),'utf8');
  assert.match(js,/wirePlayerCountPicker\('createPawnCount'\)/);
  assert.match(js,/pawn_count:Number\(els\.createPawnCount\?\.value\|\|4\)/);
});

test('pre-jogo mostra somente a quantidade configurada de peoes',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../js/ludo/render.js'),'utf8');
  assert.match(js,/pawnCount=Math\.max\(1,Math\.min\(4,\+item\?\.pawn_count\|\|4\)\)/);
  assert.match(js,/base\[color\]\.slice\(0,pawnCount\)/);
  assert.match(js,/pawn_count:state\.room\?\.room\?\.pawn_count\|\|4/);
});

test('resumo da sala mostra peoes por jogador',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../ludo.js'),'utf8');
  assert.match(js,/peões\/jogador/);
  assert.match(js,/pawn_count/);
});
