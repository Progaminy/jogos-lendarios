const JSON_HEADERS = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff'
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: JSON_HEADERS });
}

function noContent() {
  return new Response(null, { status: 204, headers: { 'Cache-Control': 'no-store' } });
}

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    throw new ApiError(400, 'JSON inválido.');
  }
}

class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function requireEnv(env) {
  for (const key of ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'ADMIN_CODE', 'ADMIN_TOKEN_SECRET']) {
    if (!env[key]) throw new ApiError(500, `Configuração ausente: ${key}`);
  }
}

function serviceHeaders(env, extra = {}) {
  return {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    ...extra
  };
}

async function supabase(env, path, options = {}) {
  const url = `${env.SUPABASE_URL.replace(/\/$/, '')}/rest/v1/${path}`;
  const response = await fetch(url, {
    ...options,
    headers: {
      ...serviceHeaders(env),
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...(options.headers || {})
    }
  });

  const text = await response.text();
  const data = text ? (() => { try { return JSON.parse(text); } catch { return text; } })() : null;
  if (!response.ok) {
    const message = typeof data === 'object' && data ? (data.message || data.error || data.details) : text;
    throw mapDatabaseError(message || 'Erro de banco de dados.');
  }
  return data;
}

function mapDatabaseError(message) {
  const text = String(message || '');
  const map = [
    ['PLAYER_NOT_FOUND', [404, 'Jogador não encontrado.']],
    ['PLAYER_BLOCKED', [403, 'Jogador bloqueado.']],
    ['INVALID_NUMBER', [400, 'Escolha um número inteiro entre 0 e 10.']],
    ['INVALID_AMOUNT', [400, 'Valor inválido.']],
    ['INSUFFICIENT_AVAILABLE_BALANCE', [409, 'Saldo disponível insuficiente. Há créditos reservados ou o saldo é menor que o valor pedido.']],
    ['INSUFFICIENT_BALANCE', [409, 'Saldo insuficiente para concluir a aprovação.']],
    ['REQUEST_NOT_FOUND', [404, 'Pedido não encontrado.']],
    ['REQUEST_ALREADY_REVIEWED', [409, 'Este pedido já foi analisado.']],
    ['RESERVED_BALANCE_CONFLICT', [409, 'O ajuste conflita com créditos reservados em levantamentos pendentes.']],
    ['INVALID_DECISION', [400, 'Decisão inválida.']]
  ];
  for (const [needle, [status, friendly]] of map) {
    if (text.includes(needle)) return new ApiError(status, friendly);
  }
  return new ApiError(500, 'Não foi possível concluir a operação no banco.');
}

function hex(bytes) {
  return [...bytes].map(b => b.toString(16).padStart(2, '0')).join('');
}

async function sha256(value) {
  const bytes = new TextEncoder().encode(String(value));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return hex(new Uint8Array(digest));
}

function randomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return hex(bytes);
}

function base64url(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function encodePayload(payload) {
  return base64url(new TextEncoder().encode(JSON.stringify(payload)));
}

async function hmac(secret, value) {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(value));
  return base64url(new Uint8Array(signature));
}

async function signAdminToken(env) {
  const payload = encodePayload({ exp: Date.now() + 8 * 60 * 60 * 1000 });
  const signature = await hmac(env.ADMIN_TOKEN_SECRET, payload);
  return `${payload}.${signature}`;
}

function decodeBase64url(text) {
  const padded = text.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((text.length + 3) % 4);
  const binary = atob(padded);
  return new Uint8Array([...binary].map(char => char.charCodeAt(0)));
}

async function verifyAdminToken(env, token) {
  if (!token || !token.includes('.')) return false;
  const [payload, signature] = token.split('.');
  const expected = await hmac(env.ADMIN_TOKEN_SECRET, payload);
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i += 1) diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  if (diff !== 0) return false;
  try {
    const decoded = JSON.parse(new TextDecoder().decode(decodeBase64url(payload)));
    return Number(decoded.exp) > Date.now();
  } catch {
    return false;
  }
}

async function safeCodeEqual(a, b) {
  const [left, right] = await Promise.all([sha256(a), sha256(b)]);
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i += 1) diff |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return diff === 0;
}

function adminBearer(request) {
  const auth = request.headers.get('Authorization') || '';
  return auth.startsWith('Bearer ') ? auth.slice(7) : '';
}

async function requireAdmin(request, env) {
  const ok = await verifyAdminToken(env, adminBearer(request));
  if (!ok) throw new ApiError(401, 'Sessão administrativa inválida ou expirada.');
}

async function requirePlayer(request, env, playerId) {
  const token = request.headers.get('X-Player-Token') || '';
  if (!token) throw new ApiError(401, 'Sessão do jogador inválida.');
  const secretHash = await sha256(token);
  const rows = await supabase(
    env,
    `players?id=eq.${encodeURIComponent(playerId)}&secret_hash=eq.${secretHash}&select=id,name,balance,blocked,created_at&limit=1`
  );
  const player = Array.isArray(rows) ? rows[0] : null;
  if (!player) throw new ApiError(401, 'Sessão do jogador inválida.');
  return player;
}

function amount(value) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 1 || number > 1000000) return null;
  return Math.round((number + Number.EPSILON) * 100) / 100;
}

function secureRandomInt11() {
  const range = 2 ** 32;
  const limit = Math.floor(range / 11) * 11;
  const values = new Uint32Array(1);
  do crypto.getRandomValues(values); while (values[0] >= limit);
  return values[0] % 11;
}

function playerView(row) {
  return {
    id: row.id,
    name: row.name,
    balance: Number(row.balance),
    blocked: Boolean(row.blocked),
    createdAt: row.created_at
  };
}

function creditView(row, playerName = '') {
  return {
    id: row.id,
    playerId: row.player_id,
    playerName,
    amount: Number(row.amount),
    note: row.note || '',
    status: row.status,
    createdAt: row.created_at,
    reviewedAt: row.reviewed_at
  };
}

function withdrawalView(row, playerName = '') {
  return {
    id: row.id,
    playerId: row.player_id,
    playerName,
    amount: Number(row.amount),
    status: row.status,
    createdAt: row.created_at,
    reviewedAt: row.reviewed_at
  };
}

function betView(row, playerName = '') {
  return {
    id: row.id,
    playerId: row.player_id,
    playerName,
    selectedNumber: row.selected_number,
    drawnNumber: row.drawn_number,
    amount: Number(row.amount),
    won: Boolean(row.won),
    payout: Number(row.payout),
    createdAt: row.created_at
  };
}

async function rpc(env, name, body) {
  return supabase(env, `rpc/${name}`, {
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify(body)
  });
}

async function playerSnapshot(request, env, playerId) {
  const player = await requirePlayer(request, env, playerId);
  const [credits, withdrawals, bets] = await Promise.all([
    supabase(env, `credit_requests?player_id=eq.${playerId}&select=*&order=created_at.desc&limit=10`),
    supabase(env, `withdrawal_requests?player_id=eq.${playerId}&select=*&order=created_at.desc&limit=10`),
    supabase(env, `bets?player_id=eq.${playerId}&select=*&order=created_at.desc&limit=20`)
  ]);
  const reserved = withdrawals
    .filter(item => item.status === 'pending')
    .reduce((sum, item) => sum + Number(item.amount), 0);
  return {
    player: playerView(player),
    availableBalance: Math.max(0, Number(player.balance) - reserved),
    reservedBalance: reserved,
    requests: credits.map(row => creditView(row)),
    withdrawals: withdrawals.map(row => withdrawalView(row)),
    bets: bets.map(row => betView(row))
  };
}

async function adminOverview(env) {
  const [players, credits, withdrawals, bets, audit] = await Promise.all([
    supabase(env, 'players?select=id,name,balance,blocked,created_at&order=created_at.desc'),
    supabase(env, 'credit_requests?status=eq.pending&select=*&order=created_at.asc'),
    supabase(env, 'withdrawal_requests?status=eq.pending&select=*&order=created_at.asc'),
    supabase(env, 'bets?select=*&order=created_at.desc&limit=200'),
    supabase(env, 'audit_log?select=*&order=created_at.desc&limit=200')
  ]);

  const names = new Map(players.map(player => [player.id, player.name]));
  const totalStaked = bets.reduce((sum, bet) => sum + Number(bet.amount), 0);
  const totalPayout = bets.reduce((sum, bet) => sum + Number(bet.payout), 0);
  const numberStats = Array.from({ length: 11 }, (_, number) => {
    const selected = bets.filter(bet => bet.selected_number === number);
    return {
      number,
      bets: selected.length,
      staked: selected.reduce((sum, bet) => sum + Number(bet.amount), 0)
    };
  });

  return {
    stats: {
      players: players.length,
      bets: bets.length,
      totalStaked,
      totalPayout,
      pendingCredits: credits.length,
      pendingWithdrawals: withdrawals.length,
      reservedCredits: withdrawals.reduce((sum, item) => sum + Number(item.amount), 0)
    },
    pendingCredits: credits.map(row => creditView(row, names.get(row.player_id) || '—')),
    pendingWithdrawals: withdrawals.map(row => withdrawalView(row, names.get(row.player_id) || '—')),
    numberStats,
    players: players.map(playerView),
    recentBets: bets.slice(0, 100).map(row => betView(row, names.get(row.player_id) || '—')),
    audit: audit.map(item => ({
      id: item.id,
      action: item.action,
      details: item.details,
      createdAt: item.created_at
    }))
  };
}

async function route(request, env) {
  requireEnv(env);
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method.toUpperCase();

  if (method === 'GET' && path === '/api/health') {
    return json({ ok: true, game: 'Numero Lendario', mode: 'virtual-credits', platform: 'cloudflare-supabase' });
  }

  if (method === 'POST' && path === '/api/players') {
    const body = await readJson(request);
    const name = String(body.name || '').trim().slice(0, 60);
    if (!name) throw new ApiError(400, 'Informe o nome do jogador.');
    const token = randomToken();
    const secretHash = await sha256(token);
    const rows = await supabase(env, 'players?select=id,name,balance,blocked,created_at', {
      method: 'POST',
      headers: { Prefer: 'return=representation' },
      body: JSON.stringify({ name, secret_hash: secretHash })
    });
    const player = rows[0];
    await supabase(env, 'audit_log', {
      method: 'POST',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ action: 'player.created', details: { playerId: player.id, name } })
    });
    return json({ player: playerView(player), token }, 201);
  }

  const playerMatch = path.match(/^\/api\/players\/([^/]+)$/);
  if (method === 'GET' && playerMatch) {
    return json(await playerSnapshot(request, env, decodeURIComponent(playerMatch[1])));
  }

  if (method === 'POST' && path === '/api/credit-requests') {
    const body = await readJson(request);
    const playerId = String(body.playerId || '');
    const value = amount(body.amount);
    const note = String(body.note || '').trim().slice(0, 160);
    if (!value) throw new ApiError(400, 'Valor de créditos inválido.');
    const player = await requirePlayer(request, env, playerId);
    if (player.blocked) throw new ApiError(403, 'Jogador bloqueado.');
    const pending = await supabase(env, `credit_requests?player_id=eq.${playerId}&status=eq.pending&select=id&limit=4`);
    if (pending.length >= 3) throw new ApiError(409, 'Existem pedidos pendentes demais para este jogador.');
    const rows = await supabase(env, 'credit_requests?select=*', {
      method: 'POST',
      headers: { Prefer: 'return=representation' },
      body: JSON.stringify({ player_id: playerId, amount: value, note })
    });
    const item = rows[0];
    await supabase(env, 'audit_log', {
      method: 'POST',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ action: 'credit.requested', details: { requestId: item.id, playerId, amount: value } })
    });
    return json({ request: creditView(item) }, 201);
  }

  if (method === 'POST' && path === '/api/withdrawals') {
    const body = await readJson(request);
    const playerId = String(body.playerId || '');
    const value = amount(body.amount);
    if (!value) throw new ApiError(400, 'Valor de levantamento inválido.');
    await requirePlayer(request, env, playerId);
    const result = await rpc(env, 'jl_request_withdrawal', { p_player_id: playerId, p_amount: value });
    return json({ request: result }, 201);
  }

  if (method === 'POST' && path === '/api/bets') {
    const body = await readJson(request);
    const playerId = String(body.playerId || '');
    const selected = Number(body.number);
    const value = amount(body.amount);
    if (!Number.isInteger(selected) || selected < 0 || selected > 10) {
      throw new ApiError(400, 'Escolha um número inteiro entre 0 e 10.');
    }
    if (!value) throw new ApiError(400, 'Valor da aposta inválido.');
    await requirePlayer(request, env, playerId);
    const drawn = secureRandomInt11();
    const result = await rpc(env, 'jl_place_bet', {
      p_player_id: playerId,
      p_selected_number: selected,
      p_amount: value,
      p_drawn_number: drawn
    });
    return json({ bet: result }, 201);
  }

  if (method === 'POST' && path === '/api/admin/login') {
    const body = await readJson(request);
    if (!(await safeCodeEqual(String(body.code || ''), String(env.ADMIN_CODE)))) {
      throw new ApiError(401, 'Código administrativo inválido.');
    }
    return json({ token: await signAdminToken(env), expiresIn: 28800 });
  }

  if (path.startsWith('/api/admin/')) await requireAdmin(request, env);

  if (method === 'POST' && path === '/api/admin/logout') return noContent();

  if (method === 'GET' && path === '/api/admin/overview') {
    return json(await adminOverview(env));
  }

  const creditReview = path.match(/^\/api\/admin\/credit-requests\/([^/]+)\/(approve|deny)$/);
  if (method === 'POST' && creditReview) {
    const decision = creditReview[2] === 'approve' ? 'approved' : 'rejected';
    const result = await rpc(env, 'jl_review_credit', {
      p_request_id: decodeURIComponent(creditReview[1]),
      p_decision: decision
    });
    return json({ request: result });
  }

  const withdrawalReview = path.match(/^\/api\/admin\/withdrawals\/([^/]+)\/(approve|deny)$/);
  if (method === 'POST' && withdrawalReview) {
    const decision = withdrawalReview[2] === 'approve' ? 'approved' : 'rejected';
    const result = await rpc(env, 'jl_review_withdrawal', {
      p_request_id: decodeURIComponent(withdrawalReview[1]),
      p_decision: decision
    });
    return json({ request: result });
  }

  const blockMatch = path.match(/^\/api\/admin\/players\/([^/]+)\/(block|unblock)$/);
  if (method === 'POST' && blockMatch) {
    const result = await rpc(env, 'jl_set_blocked', {
      p_player_id: decodeURIComponent(blockMatch[1]),
      p_blocked: blockMatch[2] === 'block'
    });
    return json(result);
  }

  const adjustMatch = path.match(/^\/api\/admin\/players\/([^/]+)\/adjust-balance$/);
  if (method === 'POST' && adjustMatch) {
    const body = await readJson(request);
    const delta = Number(body.delta);
    if (!Number.isFinite(delta) || delta === 0 || Math.abs(delta) > 1000000) {
      throw new ApiError(400, 'Ajuste inválido.');
    }
    const result = await rpc(env, 'jl_adjust_balance', {
      p_player_id: decodeURIComponent(adjustMatch[1]),
      p_delta: delta
    });
    return json(result);
  }

  throw new ApiError(404, 'Rota não encontrada.');
}

export async function onRequest(context) {
  try {
    return await route(context.request, context.env);
  } catch (error) {
    if (error instanceof ApiError) return json({ error: error.message }, error.status);
    console.error(error);
    return json({ error: 'Erro interno do servidor.' }, 500);
  }
}
