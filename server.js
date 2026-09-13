const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 3000);
const ADMIN_CODE = String(process.env.ADMIN_CODE || '');
const PUBLIC_DIR = path.join(__dirname, 'public');
const DATA_DIR = path.join(__dirname, 'data');
const STORE_FILE = path.join(DATA_DIR, 'store.json');
const MAX_BODY = 1024 * 1024;
const adminSessions = new Map();

function emptyStore() {
  return {
    players: [],
    creditRequests: [],
    bets: [],
    audit: []
  };
}

function ensureStore() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  if (!fs.existsSync(STORE_FILE)) {
    fs.writeFileSync(STORE_FILE, JSON.stringify(emptyStore(), null, 2));
  }
}

function readStore() {
  ensureStore();
  try {
    const parsed = JSON.parse(fs.readFileSync(STORE_FILE, 'utf8'));
    return {
      ...emptyStore(),
      ...parsed,
      players: Array.isArray(parsed.players) ? parsed.players : [],
      creditRequests: Array.isArray(parsed.creditRequests) ? parsed.creditRequests : [],
      bets: Array.isArray(parsed.bets) ? parsed.bets : [],
      audit: Array.isArray(parsed.audit) ? parsed.audit : []
    };
  } catch {
    return emptyStore();
  }
}

function writeStore(store) {
  ensureStore();
  const tmp = `${STORE_FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(store, null, 2));
  fs.renameSync(tmp, STORE_FILE);
}

function now() {
  return new Date().toISOString();
}

function id(prefix) {
  return `${prefix}_${crypto.randomUUID()}`;
}

function money(value) {
  return Math.round((Number(value) + Number.EPSILON) * 100) / 100;
}

function json(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff'
  });
  res.end(body);
}

function text(res, status, body, contentType = 'text/plain; charset=utf-8') {
  res.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': Buffer.byteLength(body),
    'X-Content-Type-Options': 'nosniff'
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new Error('BODY_TOO_LARGE'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(new Error('INVALID_JSON'));
      }
    });
    req.on('error', reject);
  });
}

function safeEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
}

function cleanupSessions() {
  const t = Date.now();
  for (const [token, session] of adminSessions.entries()) {
    if (session.expiresAt <= t) adminSessions.delete(token);
  }
}

function requireAdmin(req, res) {
  cleanupSessions();
  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  const session = adminSessions.get(token);
  if (!session) {
    json(res, 401, { error: 'Sessão administrativa inválida ou expirada.' });
    return null;
  }
  return { token, session };
}

function publicPlayer(player) {
  return {
    id: player.id,
    name: player.name,
    balance: player.balance,
    blocked: Boolean(player.blocked),
    createdAt: player.createdAt
  };
}

function findPlayer(store, playerId) {
  return store.players.find(p => p.id === playerId);
}

function addAudit(store, action, details = {}) {
  store.audit.unshift({
    id: id('audit'),
    action,
    details,
    createdAt: now()
  });
  store.audit = store.audit.slice(0, 1000);
}

function validateAmount(value) {
  const amount = Number(value);
  if (!Number.isFinite(amount) || amount <= 0) return null;
  const rounded = money(amount);
  if (rounded < 1 || rounded > 1000000) return null;
  return rounded;
}

async function api(req, res, url) {
  const method = req.method || 'GET';

  if (method === 'GET' && url.pathname === '/api/health') {
    return json(res, 200, { ok: true, game: 'Numero Lendario', mode: 'virtual-credits' });
  }

  if (method === 'POST' && url.pathname === '/api/players') {
    const body = await readBody(req);
    const name = String(body.name || '').trim().slice(0, 60);
    if (!name) return json(res, 400, { error: 'Informe o nome do jogador.' });

    const store = readStore();
    const player = {
      id: id('player'),
      name,
      balance: 0,
      blocked: false,
      createdAt: now()
    };
    store.players.push(player);
    addAudit(store, 'player.created', { playerId: player.id, name: player.name });
    writeStore(store);
    return json(res, 201, { player: publicPlayer(player) });
  }

  if (method === 'GET' && url.pathname.startsWith('/api/players/')) {
    const playerId = decodeURIComponent(url.pathname.slice('/api/players/'.length));
    const store = readStore();
    const player = findPlayer(store, playerId);
    if (!player) return json(res, 404, { error: 'Jogador não encontrado.' });
    const requests = store.creditRequests
      .filter(r => r.playerId === player.id)
      .slice(-10)
      .reverse();
    const bets = store.bets
      .filter(b => b.playerId === player.id)
      .slice(-20)
      .reverse();
    return json(res, 200, { player: publicPlayer(player), requests, bets });
  }

  if (method === 'POST' && url.pathname === '/api/credit-requests') {
    const body = await readBody(req);
    const amount = validateAmount(body.amount);
    const playerId = String(body.playerId || '');
    const note = String(body.note || '').trim().slice(0, 160);
    if (!amount) return json(res, 400, { error: 'Valor de créditos inválido.' });

    const store = readStore();
    const player = findPlayer(store, playerId);
    if (!player) return json(res, 404, { error: 'Jogador não encontrado.' });
    if (player.blocked) return json(res, 403, { error: 'Jogador bloqueado.' });

    const pendingCount = store.creditRequests.filter(r => r.playerId === playerId && r.status === 'pending').length;
    if (pendingCount >= 3) return json(res, 409, { error: 'Existem pedidos pendentes demais para este jogador.' });

    const request = {
      id: id('credit'),
      playerId,
      playerName: player.name,
      amount,
      note,
      status: 'pending',
      createdAt: now(),
      reviewedAt: null
    };
    store.creditRequests.push(request);
    addAudit(store, 'credit.requested', { requestId: request.id, playerId, amount });
    writeStore(store);
    return json(res, 201, { request });
  }

  if (method === 'POST' && url.pathname === '/api/bets') {
    const body = await readBody(req);
    const playerId = String(body.playerId || '');
    const selectedNumber = Number(body.number);
    const amount = validateAmount(body.amount);
    if (!Number.isInteger(selectedNumber) || selectedNumber < 0 || selectedNumber > 10) {
      return json(res, 400, { error: 'Escolha um número inteiro entre 0 e 10.' });
    }
    if (!amount) return json(res, 400, { error: 'Valor da aposta inválido.' });

    const store = readStore();
    const player = findPlayer(store, playerId);
    if (!player) return json(res, 404, { error: 'Jogador não encontrado.' });
    if (player.blocked) return json(res, 403, { error: 'Jogador bloqueado.' });
    if (player.balance < amount) return json(res, 409, { error: 'Saldo virtual insuficiente.' });

    const drawnNumber = crypto.randomInt(0, 11);
    const won = drawnNumber === selectedNumber;
    const payout = won ? money(amount * 10) : 0;
    player.balance = money(player.balance - amount + payout);

    const bet = {
      id: id('bet'),
      playerId,
      playerName: player.name,
      selectedNumber,
      drawnNumber,
      amount,
      won,
      payout,
      balanceAfter: player.balance,
      createdAt: now()
    };
    store.bets.push(bet);
    if (store.bets.length > 10000) store.bets = store.bets.slice(-10000);
    addAudit(store, 'bet.played', { betId: bet.id, playerId, selectedNumber, drawnNumber, amount, won, payout });
    writeStore(store);
    return json(res, 201, { bet, player: publicPlayer(player) });
  }

  if (method === 'GET' && url.pathname === '/api/recent-bets') {
    const store = readStore();
    const bets = store.bets.slice(-20).reverse().map(b => ({
      id: b.id,
      playerName: b.playerName,
      selectedNumber: b.selectedNumber,
      drawnNumber: b.drawnNumber,
      amount: b.amount,
      won: b.won,
      payout: b.payout,
      createdAt: b.createdAt
    }));
    return json(res, 200, { bets });
  }

  if (method === 'POST' && url.pathname === '/api/admin/login') {
    const body = await readBody(req);
    if (!ADMIN_CODE) {
      return json(res, 503, { error: 'ADMIN_CODE não foi configurado no servidor.' });
    }
    if (!safeEqual(String(body.code || ''), ADMIN_CODE)) {
      return json(res, 401, { error: 'Código de administrador inválido.' });
    }
    const token = crypto.randomBytes(32).toString('hex');
    adminSessions.set(token, { createdAt: Date.now(), expiresAt: Date.now() + 12 * 60 * 60 * 1000 });
    return json(res, 200, { token, expiresInHours: 12 });
  }

  if (url.pathname.startsWith('/api/admin/')) {
    const admin = requireAdmin(req, res);
    if (!admin) return;

    if (method === 'POST' && url.pathname === '/api/admin/logout') {
      adminSessions.delete(admin.token);
      return json(res, 200, { ok: true });
    }

    if (method === 'GET' && url.pathname === '/api/admin/overview') {
      const store = readStore();
      const totalStaked = money(store.bets.reduce((sum, b) => sum + b.amount, 0));
      const totalPayout = money(store.bets.reduce((sum, b) => sum + b.payout, 0));
      const pendingCredits = store.creditRequests.filter(r => r.status === 'pending');
      const numberStats = Array.from({ length: 11 }, (_, number) => {
        const bets = store.bets.filter(b => b.selectedNumber === number);
        return {
          number,
          bets: bets.length,
          staked: money(bets.reduce((sum, b) => sum + b.amount, 0))
        };
      });
      return json(res, 200, {
        stats: {
          players: store.players.length,
          blockedPlayers: store.players.filter(p => p.blocked).length,
          bets: store.bets.length,
          totalStaked,
          totalPayout,
          pendingCredits: pendingCredits.length
        },
        pendingCredits: pendingCredits.slice().reverse(),
        players: store.players.slice().reverse().map(publicPlayer),
        recentBets: store.bets.slice(-100).reverse(),
        numberStats,
        audit: store.audit.slice(0, 100)
      });
    }

    const creditMatch = url.pathname.match(/^\/api\/admin\/credit-requests\/([^/]+)\/(approve|deny)$/);
    if (method === 'POST' && creditMatch) {
      const requestId = decodeURIComponent(creditMatch[1]);
      const action = creditMatch[2];
      const store = readStore();
      const request = store.creditRequests.find(r => r.id === requestId);
      if (!request) return json(res, 404, { error: 'Pedido não encontrado.' });
      if (request.status !== 'pending') return json(res, 409, { error: 'Pedido já analisado.' });
      const player = findPlayer(store, request.playerId);
      if (!player) return json(res, 404, { error: 'Jogador não encontrado.' });

      request.status = action === 'approve' ? 'approved' : 'denied';
      request.reviewedAt = now();
      if (action === 'approve') player.balance = money(player.balance + request.amount);
      addAudit(store, `credit.${request.status}`, { requestId, playerId: player.id, amount: request.amount });
      writeStore(store);
      return json(res, 200, { request, player: publicPlayer(player) });
    }

    const adjustMatch = url.pathname.match(/^\/api\/admin\/players\/([^/]+)\/adjust-balance$/);
    if (method === 'POST' && adjustMatch) {
      const playerId = decodeURIComponent(adjustMatch[1]);
      const body = await readBody(req);
      const delta = Number(body.delta);
      if (!Number.isFinite(delta) || delta === 0 || Math.abs(delta) > 1000000) {
        return json(res, 400, { error: 'Ajuste inválido.' });
      }
      const store = readStore();
      const player = findPlayer(store, playerId);
      if (!player) return json(res, 404, { error: 'Jogador não encontrado.' });
      const nextBalance = money(player.balance + delta);
      if (nextBalance < 0) return json(res, 409, { error: 'O ajuste deixaria o saldo negativo.' });
      player.balance = nextBalance;
      addAudit(store, 'player.balance_adjusted', { playerId, delta: money(delta), balance: player.balance });
      writeStore(store);
      return json(res, 200, { player: publicPlayer(player) });
    }

    const blockMatch = url.pathname.match(/^\/api\/admin\/players\/([^/]+)\/(block|unblock)$/);
    if (method === 'POST' && blockMatch) {
      const playerId = decodeURIComponent(blockMatch[1]);
      const action = blockMatch[2];
      const store = readStore();
      const player = findPlayer(store, playerId);
      if (!player) return json(res, 404, { error: 'Jogador não encontrado.' });
      player.blocked = action === 'block';
      addAudit(store, `player.${action}`, { playerId });
      writeStore(store);
      return json(res, 200, { player: publicPlayer(player) });
    }

    return json(res, 404, { error: 'Rota administrativa não encontrada.' });
  }

  return json(res, 404, { error: 'Rota não encontrada.' });
}

function serveStatic(req, res, url) {
  let pathname = decodeURIComponent(url.pathname);
  if (pathname === '/') pathname = '/index.html';
  const relative = pathname.replace(/^\/+/, '');
  const filePath = path.normalize(path.join(PUBLIC_DIR, relative));
  if (!filePath.startsWith(PUBLIC_DIR + path.sep) && filePath !== PUBLIC_DIR) {
    return text(res, 403, 'Forbidden');
  }
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    return text(res, 404, 'Not found');
  }
  const ext = path.extname(filePath).toLowerCase();
  const types = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml; charset=utf-8',
    '.png': 'image/png',
    '.ico': 'image/x-icon'
  };
  const body = fs.readFileSync(filePath);
  res.writeHead(200, {
    'Content-Type': types[ext] || 'application/octet-stream',
    'Content-Length': body.length,
    'Cache-Control': ext === '.html' ? 'no-store' : 'public, max-age=300',
    'X-Content-Type-Options': 'nosniff'
  });
  res.end(body);
}

ensureStore();

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  try {
    if (url.pathname.startsWith('/api/')) {
      await api(req, res, url);
    } else {
      serveStatic(req, res, url);
    }
  } catch (error) {
    console.error(error);
    if (!res.headersSent) {
      const message = error.message === 'INVALID_JSON'
        ? 'JSON inválido.'
        : error.message === 'BODY_TOO_LARGE'
          ? 'Pedido demasiado grande.'
          : 'Erro interno do servidor.';
      json(res, error.message === 'INVALID_JSON' ? 400 : error.message === 'BODY_TOO_LARGE' ? 413 : 500, { error: message });
    }
  }
});

server.listen(PORT, () => {
  console.log(`Jogos Lendários em http://localhost:${PORT}`);
  if (!ADMIN_CODE) console.warn('AVISO: ADMIN_CODE não configurado; login administrativo está desativado.');
});
