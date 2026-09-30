'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

const html=read('aviator.html');
const css=read('aviator.css');
const js=read('aviator.js');
const ui=read('js/aviator/ui.js');

test('botão Apostar vive em slot estrutural fixo',()=>{
  assert.match(html,/class="aviator-bet-action"[\s\S]*id="betBtn"[^>]*>Apostar<\/button>[\s\S]*id="betActionStatus"/);
  assert.match(css,/\.aviator-bet-action\{display:grid;grid-template-rows:58px 16px/);
  assert.match(css,/\.aviator-bet-action #betBtn\{width:100%;height:58px;min-height:58px/);
});

test('mobile mantém botão grande em linha própria',()=>{
  assert.match(css,/\.aviator-bet-action\{grid-column:1\/-1;grid-template-rows:64px 17px/);
  assert.match(css,/\.aviator-bet-action #betBtn\{height:64px;min-height:64px;font-size:1\.2rem\}/);
});

test('texto principal do botão nunca muda com estado da rodada',()=>{
  assert.match(ui,/button\.textContent='Apostar'/);
  assert.doesNotMatch(js,/betBtn[\s\S]{0,120}textContent/);
  assert.doesNotMatch(js,/textContent='Apostas fechadas'/);
  assert.doesNotMatch(js,/textContent='Aposta confirmada'/);
  assert.doesNotMatch(js,/textContent='Aguarde'/);
});

test('estado contextual usa linha separada e fixa',()=>{
  assert.match(ui,/const statusEl=\$\('#betActionStatus'\)/);
  assert.match(ui,/statusEl\.textContent=String\(status\|\|''\)/);
  assert.match(js,/renderBetAction\(true,'Confirmando aposta…'\)/);
  assert.match(js,/renderBetAction\(true,'Apostas fechadas'\)/);
  assert.match(js,/renderBetAction\(true,'Aguarde a próxima rodada'\)/);
});

test('OPEN altera apenas disabled e status, não estrutura',()=>{
  assert.match(js,/renderBetAction\([\s\S]*?'Aposta confirmada'[\s\S]*?'Apostas fechadas'[\s\S]*?'Disponível'[\s\S]*?\);/);
});
