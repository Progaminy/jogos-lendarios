const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const runtime=require('../../js/aviator/runtime.js');

test('multiplicador começa em 1x e usa crescimento determinístico',()=>{
  assert.equal(runtime.multiplier(1000,1000),1);
  assert.equal(runtime.multiplier(2000,1000),1);
  const tenSeconds=runtime.multiplier(1000,11000);
  assert.ok(Math.abs(tenSeconds-Math.pow(1.06,10))<1e-12);
});

test('contagem de pré-voo arredonda para cima e nunca fica negativa',()=>{
  assert.equal(runtime.secondsUntil(11000,1000),10);
  assert.equal(runtime.secondsUntil(10999,1000),10);
  assert.equal(runtime.secondsUntil(1001,1000),1);
  assert.equal(runtime.secondsUntil(1000,1000),0);
  assert.equal(runtime.secondsUntil(500,1000),0);
  assert.equal(runtime.secondsUntil(Number.NaN,1000),null);
});

test('polling reduz carga fora da aba e acelera apenas durante voo',()=>{
  assert.equal(runtime.pollDelay('FLYING',false),700);
  assert.equal(runtime.pollDelay('OPEN',false),1000);
  assert.equal(runtime.pollDelay('SETTLED',false),1400);
  assert.equal(runtime.pollDelay('FLYING',true),5000);
});

test('fases públicas mapeiam para estados visuais estáveis',()=>{
  assert.equal(runtime.phase('OPEN'),'open');
  assert.equal(runtime.phase('FLYING'),'flying');
  assert.equal(runtime.phase('CRASHED'),'crashed');
  assert.equal(runtime.phase('SETTLED'),'crashed');
  assert.equal(runtime.phase('CANCELLED'),'waiting');
});

test('HTML carrega runtime antes do controlador principal',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const runtimeAt=html.indexOf('./js/aviator/runtime.js');
  const controllerAt=html.indexOf('./aviator.js');
  assert.ok(runtimeAt>=0,'runtime do Aviator deve estar incluído');
  assert.ok(controllerAt>runtimeAt,'runtime deve carregar antes de aviator.js');
});
