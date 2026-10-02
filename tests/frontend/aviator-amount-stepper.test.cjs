'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const html=fs.readFileSync('aviator.html','utf8');
const css=fs.readFileSync('aviator.css','utf8');
const stepper=fs.readFileSync('js/aviator/amount-stepper.js','utf8');
const manifest=JSON.parse(fs.readFileSync('games/manifest.json','utf8'));

test('os dois painéis começam no mínimo de 0,50 MZN',()=>{
  assert.match(html,/id="aviatorAmount"[^>]*min="0\.5"[^>]*value="0\.5"/);
  assert.match(html,/id="aviatorAmount2"[^>]*min="0\.5"[^>]*value="0\.5"/);
});

test('os dois painéis têm botões menos e mais',()=>{
  for(const id of ['aviatorAmountMinus','aviatorAmountPlus','aviatorAmountMinus2','aviatorAmountPlus2']){
    assert.match(html,new RegExp('id="'+id+'"'));
  }
  assert.match(html,/>−<\/button>/);
  assert.match(html,/>\+<\/button>/);
});

test('menos e mais variam 0,50 MZN e respeitam 0,50–500',()=>{
  assert.match(stepper,/min=\.5,max=500,step=\.5/);
  assert.match(stepper,/change\(-step\)/);
  assert.match(stepper,/change\(step\)/);
  assert.match(stepper,/Math\.min\(max,Math\.max\(min/);
  assert.match(stepper,/minus\.disabled=next<=min/);
  assert.match(stepper,/plus\.disabled=next>=max/);
});

test('controles não criam overflow no mobile',()=>{
  assert.match(css,/\.stake-stepper\{[\s\S]*?min-width:0;[\s\S]*?width:100%/);
  assert.match(css,/@media\(max-width:650px\)[\s\S]*?\.stake-stepper\{[\s\S]*?grid-template-columns:27px minmax\(0,1fr\) 27px/);
});

test('módulo do stepper carrega no Aviator e no manifesto',()=>{
  assert.match(html,/js\/aviator\/amount-stepper\.js/);
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game?.assets.includes('./js/aviator/amount-stepper.js'));
});
