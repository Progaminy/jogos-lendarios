'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('admin usa botão dedicado Fechar Aviator e não toggle genérico',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('admin.js','utf8');

  assert.match(
    html,
    /id="aviatorMaintenanceClose"[^>]*>Fechar Aviator<\/button>/
  );
  assert.doesNotMatch(html,/id="aviatorMaintenanceToggle"/);

  assert.match(js,/jl_aviator_admin_close/);
  assert.match(js,/Novas apostas e novas rodadas serão bloqueadas imediatamente/);
  assert.match(js,/A rodada atual terminará com segurança/);
  assert.match(js,/refunded_bets/);
  assert.match(js,/reembolsada/);
  assert.match(js,/refunded_total/);
  assert.match(js,/closeBtn\.disabled=!d\.enabled/);
  assert.match(js,/d\.enabled\?'Fechar Aviator':'Aviator fechado'/);

  const closeBlock=js.match(
    /\$\('aviatorMaintenanceClose'\)\?\.addEventListener\('click',[\s\S]*?\n  \}\);/
  )?.[0]||'';

  assert.match(closeBlock,/jl_aviator_admin_close/);
  assert.doesNotMatch(closeBlock,/p_enabled:true/);
  assert.doesNotMatch(closeBlock,/jl_aviator_admin_set_enabled/);
});
