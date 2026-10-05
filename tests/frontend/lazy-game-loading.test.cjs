'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const html=fs.readFileSync(path.join(root,'index.html'),'utf8');
const loader=fs.readFileSync(path.join(root,'js/platform/feature-loader.js'),'utf8');
const manifest=JSON.parse(fs.readFileSync(path.join(root,'games/manifest.json'),'utf8'));

test('home não inclui bundle do Aviator',()=>{
  const forbidden=[
    './aviator.css',
    './aviator.js',
    './js/aviator/fairness.js',
    './js/aviator/runtime.js',
    './js/realtime/aviator.js',
    '@supabase/supabase-js'
  ];
  for(const asset of forbidden){
    assert.equal(html.includes(asset),false,'home não deve carregar '+asset);
  }
});

test('links do Aviator usam navegação nativa sem route prefetch',()=>{
  const aviatorLinks=[...html.matchAll(/<a[^>]+href="\.\/aviator\.html"[^>]*>/g)].map(m=>m[0]);
  assert.ok(aviatorLinks.length>=2,'deve haver links Aviator na home');
  for(const link of aviatorLinks){
    assert.doesNotMatch(link,/data-jl-route-prefetch/);
  }
});

test('manifesto declara Aviator como rota isolada carregada na navegação',()=>{
  const game=manifest.games.find(item=>item.id==='aviator');
  assert.ok(game,'Aviator deve estar no manifesto');
  assert.equal(game.route,'./aviator.html');
  assert.equal(game.homeEmbedded,false);
  assert.equal(game.loading,'navigation');
  assert.equal(game.prefetch,'none');
  assert.ok(game.assets.includes('./aviator.css'));
  assert.ok(game.assets.includes('./aviator.js'));
});

test('todo jogo live isolado segue política lazy por padrão',()=>{
  const isolated=manifest.games.filter(item=>item.status==='live'&&item.homeEmbedded===false);
  assert.ok(isolated.length>=2);
  for(const game of isolated){
    assert.equal(game.loading,'navigation',game.id+' deve carregar na navegação');
    assert.equal(game.prefetch,'none',game.id+' não deve prefetchar bundle na home');
  }
});

test('navegação nativa é a fronteira lazy, sem loader de bundle do jogo',()=>{
  assert.match(html,/href="\.\/aviator\.html"/);
  assert.doesNotMatch(html,/href="\.\/aviator\.html"[^>]*data-jl-route-prefetch/);
  assert.doesNotMatch(loader,/installLazyGameNavigation/);
  assert.doesNotMatch(loader,/item\.assets/);
});

test('Aviator não é feature eager da página principal',()=>{
  const featuresBlock=loader.match(/const FEATURES = Object\.freeze\([\s\S]*?\n  \}\);/)?.[0]||'';
  assert.doesNotMatch(featuresBlock,/aviator/i);
});
