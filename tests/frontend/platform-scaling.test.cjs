'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

const home = fs.readFileSync('index.html', 'utf8');
const ludo = fs.readFileSync('ludo.html', 'utf8');
const styles = fs.readFileSync('styles.css', 'utf8');
const ludoCss = fs.readFileSync('ludo.css', 'utf8');
const sw = fs.readFileSync('sw.js', 'utf8');

const homeOptional = [
  'support-ui.js',
  'recovery-ui.js',
  'js/auth/player-sessions.js',
  'js/notifications/client.js',
  'promo-rotator.js',
  'number-orb.js',
  'js/player/ui.js'
];

const ludoOptional = [
  'support-ui.js',
  'recovery-ui.js',
  'js/auth/player-sessions.js',
  'js/notifications/client.js',
  'social.js'
];

test('home usa o lazy loader e não importa módulos opcionais no HTML inicial', () => {
  assert.equal(home.includes('js/platform/lazy-loader.js'), true);
  for (const path of homeOptional) {
    assert.equal(home.includes('<script src="./' + path), false, path + ' não deve estar no bundle inicial');
  }
});

test('Ludo usa o lazy loader e não importa módulos opcionais no HTML inicial', () => {
  assert.equal(ludo.includes('js/platform/lazy-loader.js'), true);
  for (const path of ludoOptional) {
    assert.equal(ludo.includes('<script src="./' + path), false, path + ' não deve estar no bundle inicial');
  }
});

test('renderização abaixo da dobra usa content-visibility', () => {
  assert.equal(styles.includes('content-visibility: auto'), true);
  assert.equal(ludoCss.includes('content-visibility: auto'), true);
  assert.equal(styles.includes('contain-intrinsic-size'), true);
  assert.equal(ludoCss.includes('contain-intrinsic-size'), true);
});

test('Service Worker não transforma estado financeiro em cache offline', () => {
  assert.equal(sw.includes("addEventListener('fetch'"), false);
  assert.equal(sw.includes('caches.'), false);
  assert.equal(/indexedDB/i.test(sw), false);
});

test('arquitectura de crescimento está documentada', () => {
  const doc = fs.readFileSync('games/ARCHITECTURE.md', 'utf8');
  assert.equal(doc.includes('Adicionar um jogo não pode aumentar o bundle inicial de outro jogo'), true);
});
