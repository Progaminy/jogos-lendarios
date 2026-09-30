'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
const engine=fs.readFileSync(path.join(__dirname,'../../js/aviator/engine.js'),'utf8');
const ui=fs.readFileSync(path.join(__dirname,'../../js/aviator/ui.js'),'utf8');
const css=fs.readFileSync(path.join(__dirname,'../../aviator.css'),'utf8');
const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');

test('perfil mobile reduz frequência de atualização visual',()=>{
  assert.match(engine,/frameIntervalMs:lowPower\?125:isMobile\?100:50/);
  assert.match(engine,/hudIntervalMs:lowPower\?300:isMobile\?250:100/);
  assert.match(engine,/openClockIntervalMs:lowPower\?750:isMobile\?500:250/);
  assert.match(engine,/navigator\?.deviceMemory/);
  assert.match(engine,/navigator\?.hardwareConcurrency/);
  assert.match(engine,/navigator\?.connection\?.saveData/);
});

test('loop visual para completamente em background',()=>{
  assert.match(js,/round\?\.status!=='FLYING'\|\|document\.hidden/);
  assert.match(js,/if\(flightFrame\|\|document\.hidden\)return/);
  assert.match(js,/stopOpenUiTick\(\);\s*stopFlight\(\);\s*scheduleState\(\)/);
});

test('HUD não é reescrito a cada frame',()=>{
  assert.match(js,/timestamp-lastFlightHudAt<visualPerformance\.hudIntervalMs/);
  assert.match(ui,/if\(el\.textContent!==text\)el\.textContent=text/);
  assert.match(ui,/if\(button\.textContent!==nextText\)button\.textContent=nextText/);
  assert.match(ui,/if\(statusEl\.textContent!==nextStatus\)statusEl\.textContent=nextStatus/);
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
  assert.match(html,/aviator\.css\?v=\d{8}-\d+/);
  assert.match(html,/aviator\.js\?v=\d{8}-\d+/);
});
