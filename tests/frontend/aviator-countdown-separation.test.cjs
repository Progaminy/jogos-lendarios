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
const engine=read('js/aviator/engine.js');

test('contagem e multiplicador têm superfícies distintas',()=>{
  assert.match(html,/id="preflightCountdown" class="countdown-value"/);
  assert.match(html,/id="multiplier" class="multiplier">1\.00×/);
  assert.match(html,/id="nextRoundSeconds"/);
  assert.match(html,/class="sr-only">Nova rodada em<\/small>/);
});

test('contagem de aposta usa número puro e multiplicador usa vezes',()=>{
  assert.match(js,/const display=seconds===null\?'—':String\(seconds\);/);
  assert.match(js,/\$\('#preflightCountdown'\)\.textContent=display/);
  assert.match(js,/toFixed\(2\)\+'×'/);
  assert.doesNotMatch(html,/countdown-value[^>]*>[^<]*×/);
});

test('OPEN e LOCKED atualizam contagem local sincronizada',()=>{
  assert.match(js,/function updateRoundClock\(\)/);
  assert.match(js,/round\?\.status==='OPEN'/);
  assert.match(js,/round\?\.status==='LOCKED'/);
  assert.match(js,/startOpenUiTick\(\)/);
  assert.match(js,/setInterval\(updateRoundClock,visualPerformance\.openClockIntervalMs\)/);
});

test('pós-crash usa next_round_at do servidor',()=>{
  assert.match(engine,/secondsToNextRound:\(\)=>secondsUntil\('next_round_at','seconds_to_next_round'\)/);
  assert.match(js,/function secondsToNextRound\(\)/);
  assert.match(js,/round\?\.status==='CRASHED'\|\|round\?\.status==='SETTLED'/);
  assert.match(js,/\$\('#nextRoundSeconds'\)/);
});

test('estilo da contagem é menor que o multiplicador e semanticamente separado',()=>{
  assert.match(css,/\.preflight \.countdown-value\{font-size:clamp\(2\.7rem,11vw,5\.2rem\)/);
  assert.match(css,/\.multiplier\{font-size:clamp\(72px,16vw,145px\)/);
  assert.match(css,/\.next-round-countdown/);
});


test('contagem principal de apostas é 10 a 0 e depois fica em AGUARDE',()=>{
  assert.match(js,/const display=seconds===null\?'—':String\(seconds\);/);
  assert.match(js,/\$\('#preflightLabel'\)\.textContent=closed\?'AGUARDE':'APOSTE'/);
  assert.match(js,/if\(round\?\.status==='LOCKED'\)[\s\S]*?preflightCountdown'\)\.textContent='0'/);
  assert.match(css,/Contagem principal: número puro, grande e estável de 10 a 0/);
  assert.match(css,/\.preflight \.countdown-value\{[\s\S]*?font-size:clamp\(4rem,15vw,7rem\)/);
});
