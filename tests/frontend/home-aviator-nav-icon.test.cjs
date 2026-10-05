'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const html=fs.readFileSync('index.html','utf8');
const css=fs.readFileSync('site-nav.css','utf8');

test('menu principal mostra símbolo de avião no lugar da palavra Aviator',()=>{
  assert.match(
    html,
    /<a class="nav-aviator-symbol" href="\.\/aviator\.html"[^>]*aria-label="Aviator"[^>]*title="Aviator"><span aria-hidden="true">✈<\/span><\/a>/
  );
  assert.doesNotMatch(
    html,
    /<a[^>]*href="\.\/aviator\.html"[^>]*>Aviator<\/a>/
  );
});

test('símbolo do avião mantém tamanho próprio no menu',()=>{
  assert.match(css,/\.game-nav a\.nav-aviator-symbol::before \{ content: none; \}/);
  assert.match(css,/\.game-nav a\.nav-aviator-symbol > span \{[\s\S]*?font-size: 2rem/);
  assert.match(css,/@media \(max-width: 900px\)[\s\S]*?\.game-nav a\.nav-aviator-symbol > span \{[\s\S]*?font-size: 1\.7rem/);
});
