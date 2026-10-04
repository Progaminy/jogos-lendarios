'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'js/ludo/render.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'ludo.html'), 'utf8');

test('tabuleiro inicial do Ludo é desenhado antes do estado remoto', () => {
  assert.match(source, /function renderLobbyBoard\(\)\s*\{[\s\S]*?renderStaticBoard\(els\.ludoLobbyBoard\);[\s\S]*?\}/);
  assert.match(source, /renderLobbyBoard\(\);\s*\n\s*return Object\.freeze/);
});

test('página mantém o contentor do tabuleiro inicial', () => {
  assert.match(html, /id="ludoLobbyBoard"[^>]*class="ludo-board"/);
});
