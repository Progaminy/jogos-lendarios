'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('admin usa Reabrir Aviator separado e com confirmação',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('js/aviator/admin.js','utf8');

  assert.match(
    html,
    /id="aviatorMaintenanceReopen"[^>]*>Reabrir Aviator<\/button>/
  );
  assert.match(html,/id="aviatorMaintenanceClose"[^>]*>Fechar Aviator<\/button>/);

  assert.match(js,/jl_aviator_admin_reopen/);
  assert.match(js,/Reabrir Aviator agora\?/);
  assert.match(js,/Novas rodadas e novas apostas voltarão a ser permitidas/);
  assert.match(js,/window\.confirm/);
  assert.match(js,/Aguarde a rodada atual terminar antes de reabrir o Aviator/);

  const reopenBlock=js.match(
    /\$\('aviatorMaintenanceReopen'\)\?\.addEventListener\('click',[\s\S]*?\n\s*\}\);/
  )?.[0]||'';

  assert.match(reopenBlock,/jl_aviator_admin_reopen/);
  assert.match(reopenBlock,/window\.confirm/);
  assert.doesNotMatch(reopenBlock,/jl_aviator_admin_close/);
  assert.doesNotMatch(reopenBlock,/p_enabled:false/);
});

test('reabrir fica desativado enquanto aberto ou em drenagem',()=>{
  const js=fs.readFileSync('js/aviator/admin.js','utf8');

  assert.match(
    js,
    /const draining=\s*!d\.enabled&&\['OPEN','LOCKED','FLYING','CRASHED'\]/
  );
  assert.match(js,/reopenBtn\.disabled=Boolean\(d\.enabled\)\|\|draining/);
  assert.match(js,/d\.enabled\s*\?'Aviator aberto'/);
  assert.match(js,/draining\s*\?'Aguarde a rodada atual'/);
});
