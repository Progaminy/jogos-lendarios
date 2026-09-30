'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
const css=fs.readFileSync(path.join(__dirname,'../../aviator.css'),'utf8');
const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');

test('perfil mobile reduz frequência de atualização visual',()=>{
  assert.match(js,/frameIntervalMs:lowPower\?125:isMobile\?100:50/);
  assert.match(js,/hudIntervalMs:lowPower\?300:isMobile\?250:100/);
  assert.match(js,/openClockIntervalMs:lowPower\?750:isMobile\?500:250/);
  assert.match(js,/navigator\.deviceMemory/);
  assert.match(js,/navigator\.hardwareConcurrency/);
  assert.match(js,/navigator\.connection\?\.saveData/);
});

test('loop visual para completamente em background',()=>{
  assert.match(js,/round\?\.status!=='FLYING'\|\|document\.hidden/);
  assert.match(js,/if\(flightFrame\|\|document\.hidden\)return/);
  assert.match(js,/stopOpenUiTick\(\);\s*stopFlight\(\);\s*scheduleState\(\)/);
});

test('HUD não é reescrito a cada frame',()=>{
  assert.match(js,/timestamp-lastFlightHudAt<visualPerformance\.hudIntervalMs/);
  assert.match(js,/if\(el\.textContent!==text\)el\.textContent=text/);
  assert.match(js,/if\(cashout\.textContent!==text\)cashout\.textContent=text/);
});

test('mobile remove efeitos de pintura caros',()=>{
  assert.match(css,/@media\(max-width:650px\)/);
  assert.match(css,/\.flight-grid\{display:none\}/);
  assert.match(css,/\.plane\{font-size:50px;filter:none\}/);
  assert.match(css,/\.flight-area::after\{animation:none!important;opacity:\.28\}/);
  assert.match(css,/contain:layout paint style/);
  assert.match(css,/#cashoutBtn:not\(:disabled\)\{box-shadow:0 0 0 1px/);
});

test('modo low power mantém animação transform mas corta decoração',()=>{
  assert.match(css,/\.aviator-low-power \.flight-grid\{display:none\}/);
  assert.match(css,/\.aviator-low-power \.flight-area::after\{display:none\}/);
  assert.match(css,/\.aviator-low-power \.plane\{filter:none\}/);
  assert.match(css,/\.aviator-low-power \.aviator-stage\.is-open \.plane\{animation:none\}/);
});

test('assets mobile otimizados têm cache-bust dedicado',()=>{
  assert.match(html,/aviator\.css\?v=20260930-14/);
  assert.match(html,/aviator\.js\?v=20260930-5/);
});
