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

test('a única contagem numérica visível é a janela de apostas 10 a 0',()=>{
  assert.match(html,/id="preflightCountdown" class="countdown-value"/);
  assert.match(js,/const display=seconds===null\?'—':String\(seconds\);/);
  assert.match(js,/\$\('#preflightCountdown'\)\.textContent=display/);
  assert.match(js,/\$\('#roundCountdown'\)\.textContent=closed\?'FECHADO':'ABERTO'/);
  assert.match(html,/id="nextRoundCountdown" class="next-round-countdown hidden"/);
});

test('LOCKED prepara o voo sem mostrar outra contagem',()=>{
  const locked=js.match(/if\(round\?\.status==='LOCKED'\)\{[\s\S]*?return;\n  \}/)?.[0]||'';
  assert.match(locked,/clockLabel'\)\.textContent='PREPARANDO'/);
  assert.match(locked,/roundCountdown'\)\.textContent='—'/);
  assert.match(locked,/preflightCountdown'\)\.textContent=''/);
});

test('pós-crash não mostra contagem adicional para a próxima rodada',()=>{
  const finished=js.match(/if\(round\?\.status==='CRASHED'\|\|round\?\.status==='SETTLED'\)\{[\s\S]*?return;\n  \}/)?.[0]||'';
  assert.match(finished,/roundCountdown'\)\.textContent='—'/);
  assert.match(finished,/nextRoundSeconds/);
  assert.match(finished,/textContent=''/);
});

test('multiplicador continua semanticamente separado da contagem',()=>{
  assert.match(html,/id="multiplier" class="multiplier">1\.00×/);
  assert.match(css,/\.multiplier\{font-size:clamp\(72px,16vw,145px\)/);
});
