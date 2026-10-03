'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const social=fs.readFileSync(path.join(__dirname,'../../social.js'),'utf8');
const loader=fs.readFileSync(path.join(__dirname,'../../js/platform/ludo-feature-loader.js'),'utf8');

test('contador online abre lista de jogadores online',()=>{
  assert.match(social,/id="socialOnlineCount"[^>]*aria-controls="socialOnlinePanel"/);
  assert.match(social,/id="socialOnlineList"/);
  assert.match(social,/jl_social_online_players/);
  assert.match(social,/state\.onlinePlayers/);
  assert.match(social,/state\.onlineOpen = !state\.onlineOpen/);
  assert.match(social,/playerHtml\(player, 'online'\)/);
});

test('listas sociais mantêm botão pequeno de convidar no Ludo',()=>{
  assert.match(social,/document\.getElementById\('room'\) \|\| window\.JLLudoSocial/);
  assert.match(social,/data-social-invite=/);
  assert.match(social,/>Convidar<\/button>/);
  assert.doesNotMatch(social,/JLLudoSocial\.canInvite\(\).*data-social-invite/);
});

test('deixar de seguir exige confirmação',()=>{
  assert.match(social,/!follow && !window\.confirm\('Tem certeza que deseja deixar de seguir este jogador\?'\)/);
  assert.match(social,/changeFollow\(target, follow, button\)/);
});

test('loader usa versão nova do módulo social',()=>{
  assert.match(loader,/social\.js\?v=20261003-5/);
});

test('botão superior online abre diretório global e lista inclui o próprio jogador',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../ludo.html'),'utf8');
  const migration=fs.readFileSync(path.join(__dirname,'../../supabase/migrations/20261003075316_ludo_online_list_matches_counter.sql'),'utf8');
  assert.match(html,/<button class="status-metric online-metric"[^>]*aria-label="Ver jogadores online"/);
  assert.match(social,/const self = Boolean\(player\.is_self\)/);
  assert.match(social,/self \? '<span class="jl-social-tag">Você<\/span>'/);
  assert.match(social,/self \? '' :/);
  assert.match(migration,/'is_self', x\.id = me/);
  assert.doesNotMatch(migration,/p\.id <> me/);
});


test('botão online abre a lista abaixo do contador sem deslocar a página',()=>{
  assert.match(social,/statusStrip\.insertAdjacentElement\('afterend', ui\.onlinePanel\)/);
  assert.match(social,/metric\.addEventListener\('click', toggleOnlineDirectory\)/);
  assert.match(social,/ui\.onlinePanel\?\.addEventListener\('click', handleSocialAction\)/);
  const metricBlock=social.slice(social.indexOf("const metric = document.querySelector('.online-metric')"),social.indexOf('return true;',social.indexOf("const metric = document.querySelector('.online-metric')")));
  assert.doesNotMatch(metricBlock,/scrollIntoView/);
  assert.doesNotMatch(metricBlock,/\.jl-collapse-body/);
});
