'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const stripQuery = (value) => String(value || '').split('?')[0].replace(/^\.\//, '');

function scriptSources(html) {
  return [...html.matchAll(/<script\b[^>]*\bsrc=["']([^"']+)["'][^>]*>/gi)].map((m) => m[1]);
}

function styleSources(html) {
  return [...html.matchAll(/<link\b[^>]*\brel=["']stylesheet["'][^>]*\bhref=["']([^"']+)["'][^>]*>/gi)].map((m) => m[1]);
}

function localBytes(sources) {
  return sources.reduce((total, source) => {
    const file = stripQuery(source);
    if (!file || /^https?:/i.test(file)) return total;
    const full = path.join(root, file);
    return total + (fs.existsSync(full) ? fs.statSync(full).size : 0);
  }, 0);
}

test('home does not eagerly load optional shared features', () => {
  const html = read('index.html');
  const scripts = scriptSources(html).map(stripQuery);
  const styles = styleSources(html).map(stripQuery);

  for (const optional of [
    'support-ui.js',
    'recovery-ui.js',
    'js/notifications/client.js',
    'js/auth/player-sessions.js',
    'promo-rotator.js',
    'number-orb.js',
    'js/player/ui.js'
  ]) {
    assert.equal(scripts.includes(optional), false, optional + ' voltou ao carregamento inicial');
  }

  assert.equal(styles.includes('support-ui.css'), false);
  assert.equal(styles.includes('recovery-ui.css'), false);
  assert.ok(scripts.includes('js/platform/feature-loader.js'));
});

test('home initial JavaScript source budget stays below 90 KiB', () => {
  const html = read('index.html');
  const bytes = localBytes(scriptSources(html));
  assert.ok(bytes <= 90 * 1024, 'JS inicial da home cresceu para ' + bytes + ' bytes');
});

test('home initial CSS source budget stays below 45 KiB', () => {
  const html = read('index.html');
  const bytes = localBytes(styleSources(html));
  assert.ok(bytes <= 45 * 1024, 'CSS inicial da home cresceu para ' + bytes + ' bytes');
});

test('future game bundles stay route-isolated', () => {
  const html = read('index.html');
  const scripts = scriptSources(html).map(stripQuery);
  const manifest = JSON.parse(read('games/manifest.json'));

  for (const game of manifest.games) {
    if (game.homeEmbedded || game.status !== 'live') continue;
    assert.ok(game.route, game.id + ' precisa de rota própria');
    for (const asset of game.assets || []) {
      const file = stripQuery(asset);
      assert.equal(scripts.includes(file), false, file + ' não pode ser eager na home');
    }
  }
});

test('below-the-fold home sections use deferred browser rendering', () => {
  const html = read('index.html');
  for (const id of ['sorteios', 'numero-lendario', 'dupla-lendaria', 'playerArea']) {
    assert.match(html, new RegExp('id=["\\\']' + id + '["\\\'][^>]*class=["\\\'][^"\\\']*jl-deferred-render'));
  }
  assert.match(read('styles.css'), /content-visibility:\s*auto/);
});

test('optional loader respects data-saving networks before route prefetch', () => {
  const source = read('js/platform/feature-loader.js');
  assert.match(source, /connection\.saveData/);
  assert.match(source, /slow-2g/);
  assert.match(source, /2g/);
  assert.match(source, /data-jl-route-prefetch/);
});

test('Ludo remains isolated from the home bundle', () => {
  const home = read('index.html');
  const homeScripts = scriptSources(home).map(stripQuery);
  assert.equal(homeScripts.includes('ludo.js'), false);
  assert.equal(homeScripts.some((src) => src.startsWith('js/ludo/')), false);
  assert.match(read('ludo.html'), /src=["']\.\/ludo\.js\?/);
});


test('Ludo optional shared features are not eager', () => {
  const html = read('ludo.html');
  const scripts = scriptSources(html).map(stripQuery);
  const styles = styleSources(html).map(stripQuery);

  for (const optional of [
    'support-ui.js',
    'recovery-ui.js',
    'js/notifications/client.js',
    'js/auth/player-sessions.js',
    'social.js'
  ]) {
    assert.equal(scripts.includes(optional), false, optional + ' voltou ao carregamento inicial do Ludo');
  }

  assert.equal(styles.includes('support-ui.css'), false);
  assert.equal(styles.includes('recovery-ui.css'), false);
  assert.ok(scripts.includes('js/platform/ludo-feature-loader.js'));
  assert.equal(scripts.includes('js/platform/feature-loader.js'),false);
});

test('Ludo initial JavaScript source budget stays below 145 KiB', () => {
  const html = read('ludo.html');
  const bytes = localBytes(scriptSources(html));
  assert.ok(bytes <= 145 * 1024, 'JS inicial do Ludo cresceu para ' + bytes + ' bytes');
});

test('Ludo initial CSS source budget stays below 50 KiB', () => {
  const html = read('ludo.html');
  const bytes = localBytes(styleSources(html));
  assert.ok(bytes <= 50 * 1024, 'CSS inicial do Ludo cresceu para ' + bytes + ' bytes');
});

test('only one platform feature loader is eager per page', () => {
  const homeScripts=scriptSources(read('index.html')).map(stripQuery);
  const ludoScripts=scriptSources(read('ludo.html')).map(stripQuery);
  assert.equal(homeScripts.includes('js/platform/lazy-loader.js'),false);
  assert.equal(ludoScripts.includes('js/platform/lazy-loader.js'),false);
  assert.equal(homeScripts.filter(src=>src==='js/platform/feature-loader.js').length,1);
  assert.equal(ludoScripts.filter(src=>src==='js/platform/ludo-feature-loader.js').length,1);
  assert.equal(ludoScripts.includes('js/platform/feature-loader.js'),false);
});

test('Service Worker keeps authoritative game and money state online-only', () => {
  const sw = read('sw.js');
  assert.equal(sw.includes("addEventListener('fetch'"), false);
  assert.equal(sw.includes('caches.'), false);
  assert.equal(/indexedDB/i.test(sw), false);
});
