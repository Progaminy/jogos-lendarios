'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const css=fs.readFileSync(path.join(root,'aviator.css'),'utf8');
const js=fs.readFileSync(path.join(root,'aviator.js'),'utf8');
const html=fs.readFileSync(path.join(root,'aviator.html'),'utf8');

test('crash entra rápido e não possui animação de saída longa',()=>{
  assert.match(css,/\.aviator-stage\.is-crashed \.crash-text:not\(\.hidden\)\{animation:aviatorCrashIn \.16s ease-out both\}/);
  assert.match(css,/@keyframes aviatorCrashIn\{0%\{opacity:0;transform:scale\(\.94\)\}100%\{opacity:1;transform:scale\(1\)\}\}/);
  assert.doesNotMatch(css,/aviatorCrashOut|crashExit|fadeOut.*crash/i);
});

test('avião e trilha param imediatamente no crash',()=>{
  assert.match(css,/\.aviator-stage\.is-crashed \.plane\{opacity:0;animation:none\}/);
  assert.match(css,/\.aviator-stage\.is-crashed \.flight-area::after\{opacity:0;animation:none\}/);
});

test('renderFinished não espera animação antes de liberar próximo estado',()=>{
  const block=js.match(/function renderFinished\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(block,/setStagePhase\('crashed'\)/);
  assert.match(block,/show\('#crashText',true\)/);
  assert.doesNotMatch(block,/setTimeout|await |sleep|delay|transitionend|animationend/);
});

test('reduced motion elimina até a curta animação de crash',()=>{
  const reduced=css.match(/@media\(prefers-reduced-motion:reduce\)\{[\s\S]*?\n\}/)?.[0]||'';
  assert.match(reduced,/\.aviator-stage\.is-crashed \.crash-text:not\(\.hidden\)/);
  assert.match(reduced,/animation:none!important/);
});

test('asset de crash usa cache-bust próprio',()=>{
  assert.match(html,/aviator\.css\?v=20261001-3/);
});
