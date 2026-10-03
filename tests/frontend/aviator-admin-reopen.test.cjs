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

  const reopenBlock=js.slice(
    js.indexOf("$('aviatorMaintenanceReopen')?.addEventListener('click'"),
    js.indexOf("$('aviatorOneRoundTest')?.addEventListener('click'")
  );

  assert.match(reopenBlock,/jl_aviator_admin_reopen/);
  assert.match(reopenBlock,/Reabrir Aviator agora\?/);
  assert.match(reopenBlock,/Novas rodadas e novas apostas voltarão a ser permitidas/);
  assert.match(reopenBlock,/window\.confirm/);
  assert.doesNotMatch(reopenBlock,/jl_aviator_admin_close/);
  assert.doesNotMatch(reopenBlock,/jl_aviator_admin_release_gate/);
  assert.doesNotMatch(reopenBlock,/Aguarde a rodada atual terminar/);
});

test('reabrir só fica desativado quando o Aviator já está aberto',()=>{
  const js=fs.readFileSync('js/aviator/admin.js','utf8');

  assert.match(js,/reopenBtn\.disabled=Boolean\(d\.enabled\);/);
  assert.match(js,/reopenBtn\.textContent=d\.enabled\?'Aviator aberto':'Reabrir Aviator'/);
  assert.match(js,/reopenBtn\.classList\.toggle\('success',!d\.enabled\)/);
  assert.match(js,/FECHADO · NÃO CERTIFICADO/);
});

test('reabertura não depende dos testes automáticos para autorizar abertura',()=>{
  const js=fs.readFileSync('js/aviator/admin.js','utf8');
  const reopenBlock=js.slice(
    js.indexOf("$('aviatorMaintenanceReopen')?.addEventListener('click'"),
    js.indexOf("$('aviatorOneRoundTest')?.addEventListener('click'")
  );

  assert.match(reopenBlock,/button\.textContent='Reabrindo…'/);
  assert.match(reopenBlock,/Aviator reaberto\. Novas rodadas e apostas estão permitidas/);
  assert.doesNotMatch(reopenBlock,/engineTest/);
  assert.doesNotMatch(reopenBlock,/passed\/.*total/);
});
