'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('Aviator aceita valor minimo de 0,50 no cliente',()=>{
  const html=fs.readFileSync('aviator.html','utf8');
  const js=fs.readFileSync('aviator.js','utf8');

  assert.match(html,/id="aviatorAmount"[^>]*min="0\.5"/);
  assert.match(html,/id="aviatorAmount"[^>]*max="500"/);
  assert.match(html,/id="aviatorAmount"[^>]*step="0\.01"/);
  assert.match(html,/inputmode="decimal"/);
  assert.match(js,/amount<0\.5/);
  assert.match(js,/amount>500/);
  assert.match(js,/entre 0,50 e 500\./);
  assert.doesNotMatch(html,/>MZN</);
});

test('Aviator nao volta silenciosamente ao minimo antigo de 1',()=>{
  const js=fs.readFileSync('aviator.js','utf8');
  assert.doesNotMatch(js,/amount<1\)/);
});
