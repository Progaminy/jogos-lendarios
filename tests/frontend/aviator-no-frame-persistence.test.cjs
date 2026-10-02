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
