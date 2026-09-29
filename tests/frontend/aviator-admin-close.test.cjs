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
  assert.match(js,/A rodada atual terminará com segurança/);
  assert.match(js,/refunded_bets/);
  assert.match(js,/reembolsada/);
  assert.match(js,/refunded_total/);
  assert.match(js,/closeBtn\.disabled=!d\.enabled/);
  assert.match(js,/d\.enabled\?'Fechar Aviator':'Aviator fechado'/);

  assert.match(js,/async function closeAviatorFromAdmin/);
  assert.match(js,/window\.JLCloseAviator=closeAviatorFromAdmin/);
  assert.match(js,/document\.addEventListener\('click'/);
  assert.match(js,/jl_aviator_admin_close/);
  assert.match(js,/Falha ao fechar Aviator:/);
  assert.doesNotMatch(js,/Fechar Aviator agora\?/);
  assert.doesNotMatch(js,/jl_aviator_admin_set_enabled\(.*true/);
});
