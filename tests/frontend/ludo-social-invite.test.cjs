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
  assert.match(social,/state\.onlineOpen = true/);
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
  assert.match(loader,/social\.js\?v=20261003-2/);
});
