'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
const engine=fs.readFileSync(path.join(__dirname,'../../js/aviator/engine.js'),'utf8');

test('loop visual do multiplicador não persiste frames',()=>{
  const paint=js.match(/function paintFlight\([\s\S]*?\n\}/)?.[0]||'';
  const loop=js.match(/function flightPaintLoop\([\s\S]*?\n\}/)?.[0]||'';

  assert.doesNotMatch(paint,/JLApi\.rpc|fetch\(|insert|update|audit/i);
  assert.doesNotMatch(loop,/JLApi\.rpc|fetch\(|insert|update|audit/i);
  assert.match(loop,/requestAnimationFrame\(flightPaintLoop\)/);
});

test('multiplicador visual usa somente frame confirmado pelo servidor, sem histórico remoto',()=>{
  assert.match(engine,/round\?\.current_multiplier/);
  assert.doesNotMatch(engine,/runtime\.liveMultiplier\(/);
  assert.doesNotMatch(js,/multiplier_history|frame_history|visual_history|tick_history/);
});


test('avião avança continuamente e nunca reinicia em loop CSS',()=>{
  const ui=fs.readFileSync(path.join(__dirname,'../../js/aviator/ui.js'),'utf8');
  const css=fs.readFileSync(path.join(__dirname,'../../aviator.css'),'utf8');

  assert.match(ui,/function renderPlaneFlight\(multiplierValue,timestamp=performance\.now\(\)\)/);
  assert.match(ui,/progress=Math\.max\(lastPlaneProgress,progress\)/);
  assert.match(ui,/lastPlaneProgress=progress/);
  assert.match(ui,/Math\.log\(safe\)\/Math\.log\(500\)/);
  assert.match(ui,/Math\.sin\(Number\(timestamp\)\/210\)\*2/);
  assert.match(js,/ui\.renderPlaneFlight\?\.\(m,timestamp\)/);
  assert.doesNotMatch(css,/animation:aviatorFlight[^;]*infinite/);
  assert.doesNotMatch(css,/@keyframes aviatorFlight/);
});
