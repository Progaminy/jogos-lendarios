const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('pontos 65-67: admin mostra métricas, alarme financeiro e certificação real',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('js/aviator/admin.js','utf8');

  for(const id of [
    'aviatorMetricRoundDuration',
    'aviatorMetricBetsPerSec',
    'aviatorMetricCashoutsPerSec',
    'aviatorMetricLatency',
    'aviatorMetricPaymentFailures',
    'aviatorFinancialConsistency',
    'aviatorReleaseGateStatus',
    'aviatorReleaseGateDetail',
    'aviatorFinancialAlert'
  ]){
    assert.match(html,new RegExp('id="'+id+'"'));
  }

  assert.match(js,/jl_aviator_admin_observability/);
  assert.match(js,/jl_aviator_admin_release_gate_state/);
  assert.match(js,/jl_aviator_admin_release_gate/);
  assert.match(js,/NÃO CERTIFICADO/);
  assert.match(js,/FECHADO · NÃO CERTIFICADO/);
  assert.match(js,/CERTIFICADO/);
  assert.match(js,/DIVERGÊNCIA/);
  assert.match(js,/latency_p95_ms_15m/);
  assert.match(js,/failures_15m/);
});

test('ponto 67: botão Testar motor usa gate completo, não apenas preflight estrutural',()=>{
  const js=fs.readFileSync('js/aviator/admin.js','utf8');

  const block=js.match(/\$\('aviatorEnginePreflight'\)\?\.addEventListener\('click',[\s\S]*?\n    \}\);/)?.[0]||'';
  assert.match(block,/jl_aviator_admin_release_gate/);
  assert.match(block,/repeated_flow/);
  assert.match(block,/financial_consistency/);
  assert.doesNotMatch(block,/jl_aviator_admin_engine_preflight/);
});


test('ponto 65: telemetria falhada fica em fila e é reenviada após recuperação',()=>{
  const financial=fs.readFileSync('js/aviator/financial.js','utf8');
  assert.match(financial,/jl_aviator_metric_queue_v1/);
  assert.match(financial,/function queueMetric\(/);
  assert.match(financial,/async function flushPendingMetrics\(/);
  assert.match(financial,/queueMetric\(metric\)/);
  assert.match(financial,/void flushPendingMetrics\(\)/);
  assert.match(financial,/slice\(-20\)/);
});
