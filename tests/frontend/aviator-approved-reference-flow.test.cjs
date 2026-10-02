'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const html=fs.readFileSync('aviator.html','utf8');
const css=fs.readFileSync('aviator.css','utf8');
const js=fs.readFileSync('aviator.js','utf8');

test('histórico recente de multiplicadores fica no topo do Aviator',()=>{
  const historyAt=html.indexOf('id="aviatorHistoryCard"');
  const stageAt=html.indexOf('id="aviatorStage"');
  assert.ok(historyAt>=0&&stageAt>=0&&historyAt<stageAt);
  assert.match(html,/Últimos multiplicadores/);
  assert.match(html,/id="aviatorHistory" class="aviator-history-strip"/);
  assert.match(css,/\.aviator-history-top/);
});

test('durante voo não existe segunda etapa de preparação de aposta',()=>{
  const flying=js.match(/function renderFlying\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(flying,/setBetInputsLocked\(true\)/);
  assert.match(flying,/renderAutoBetStatus\(\)/);
  assert.doesNotMatch(flying,/queue-next|Prepare a próxima|Próxima aposta preparada/);
});

test('auto-bet só dispara quando servidor informa OPEN',()=>{
  const fn=js.match(/function scheduleAutoBetForOpenRound\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(fn,/round\?\.status!=='OPEN'/);
  assert.match(fn,/round\?\.betting_open===false/);
  assert.match(fn,/playerToken\(\)/);
  assert.match(fn,/requestSubmit/);
  assert.match(fn,/autoBetAttemptedRoundId===roundId/);
});

test('auto-bet usa o mesmo fluxo financeiro normal e não debita antecipadamente',()=>{
  assert.match(js,/autoBetSubmittingRoundId=roundId/);
  assert.match(js,/\$\('#aviatorBetForm'\)\?\.requestSubmit/);
  const fn=js.match(/function scheduleAutoBetForOpenRound\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.doesNotMatch(fn,/jl_aviator_place_bet|JLApi\.rpc|financial\.placeBet/);
});

test('auto-bet aguarda OPEN e não cria etapa de preparação visível',()=>{
  assert.match(html,/id="aviatorAutoBet"/);
  assert.match(html,/id="aviatorAutoBetStatus"/);
  assert.doesNotMatch(js,/Próxima aposta preparada|Prepare a próxima rodada/);
  assert.match(js,/Aposta automática confirmada para esta rodada/);
});

test('contagem regressiva permanece separada do multiplicador',()=>{
  assert.match(html,/id="roundCountdown"/);
  assert.match(html,/id="preflightCountdown"/);
  assert.match(html,/id="multiplier"/);
  assert.match(html,/id="nextRoundSeconds"/);
});
