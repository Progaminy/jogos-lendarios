const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, x-player-token',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

const JSON_HEADERS = {
  ...CORS_HEADERS,
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
};

class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: JSON_HEADERS });
}
function noContent() {
  return new Response(null, { status: 204, headers: { ...CORS_HEADERS, 'Cache-Control': 'no-store' } });
}
async function readJson(request) {
  try { return await request.json(); } catch { throw new ApiError(400, 'JSON inválido.'); }
}
function runtimeEnv() {
  const url = Deno.env.get('SUPABASE_URL') || '';
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!url || !key) throw new ApiError(500, 'Configuração do servidor incompleta.');
  return { url, key };
}
async function db(path, options = {}) {
  const { url, key } = runtimeEnv();
  const response = await fetch(`${url.replace(/\/$/, '')}/rest/v1/${path}`, {
    ...options,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...(options.headers || {}),
    },
  });
  const text = await response.text();
  let data = null;
  if (text) { try { data = JSON.parse(text); } catch { data = text; } }
  if (!response.ok) {
    const msg = data && typeof data === 'object' ? String(data.message || data.error || data.details || '') : String(text || '');
    if (msg.includes('duplicate key') && msg.includes('players_phone_unique')) throw new ApiError(409, 'Este número de telefone já está cadastrado.');
    const map = [
      ['PLAYER_NOT_FOUND', 404, 'Jogador não encontrado.'],
      ['PLAYER_BLOCKED', 403, 'Jogador bloqueado.'],
      ['INVALID_NUMBER', 400, 'Escolha um número inteiro entre 0 e 10.'],
      ['INVALID_AMOUNT', 400, 'Valor inválido.'],
      ['INSUFFICIENT_AVAILABLE_BALANCE', 409, 'Saldo disponível insuficiente.'],
      ['INSUFFICIENT_BALANCE', 409, 'Saldo insuficiente.'],
      ['REQUEST_NOT_FOUND', 404, 'Pedido não encontrado.'],
      ['REQUEST_ALREADY_REVIEWED', 409, 'Este pedido já foi analisado.'],
      ['RESERVED_BALANCE_CONFLICT', 409, 'O ajuste conflita com saldo reservado.'],
      ['INVALID_DECISION', 400, 'Decisão inválida.'],
    ];
    for (const [needle, status, friendly] of map) if (msg.includes(needle)) throw new ApiError(status, friendly);
    throw new ApiError(500, 'Não foi possível concluir a operação no banco.');
  }
  return data;
}
function hex(bytes) { return [...bytes].map(b => b.toString(16).padStart(2, '0')).join(''); }
async function sha256(value) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(String(value)));
  return hex(new Uint8Array(digest));
}
function randomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return hex(bytes);
}
function normalizePhone(value) {
  const digits = String(value || '').replace(/\D/g, '');
  if (digits.length < 8 || digits.length > 15) return null;
  return digits;
}
function validPin(value) {
  const pin = String(value || '');
  return /^\d{4,8}$/.test(pin) ? pin : null;
}
function amount(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n < 1 || n > 1000000) return null;
  return Math.round((n + Number.EPSILON) * 100) / 100;
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
    phone: row.phone || '',
    balance: Number(row.balance || 0),
    blocked: Boolean(row.blocked),
    createdAt: row.created_at,
  };
}
function creditView(row, playerName = '') {
  return { id: row.id, playerId: row.player_id, playerName, amount: Number(row.amount), note: row.note || '', status: row.status, createdAt: row.created_at, reviewedAt: row.reviewed_at };
}
function withdrawalView(row, playerName = '') {
  return { id: row.id, playerId: row.player_id, playerName, amount: Number(row.amount), status: row.status, createdAt: row.created_at, reviewedAt: row.reviewed_at };
}
function betView(row, playerName = '') {
  return { id: row.id, playerId: row.player_id, playerName, selectedNumber: row.selected_number, drawnNumber: row.drawn_number, amount: Number(row.amount), won: Boolean(row.won), payout: Number(row.payout), createdAt: row.created_at };
}
async function rpc(name, body) {
  return await db(`rpc/${name}`, {
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify(body),
  });
}
async function requirePlayer(request, playerId) {
  const token = request.headers.get('X-Player-Token') || '';
  if (!token) throw new ApiError(401, 'Sessão do jogador inválida.');
  const secretHash = await sha256(token);
  const rows = await db(`players?id=eq.${encodeURIComponent(playerId)}&secret_hash=eq.${secretHash}&select=id,name,phone,balance,blocked,created_at&limit=1`);
  const player = Array.isArray(rows) ? rows[0] : null;
  if (!player) throw new ApiError(401, 'Sessão do jogador inválida.');
  return player;
}
function adminToken(request) {
  const auth = request.headers.get('Authorization') || '';
  return auth.startsWith('Bearer ') ? auth.slice(7) : '';
}
async function requireAdmin(request) {
  const token = adminToken(request);
  if (!token) throw new ApiError(401, 'Sessão administrativa inválida ou expirada.');
  const tokenHash = await sha256(token);
  const rows = await db(`admin_sessions?token_hash=eq.${tokenHash}&select=id,expires_at&limit=1`);
  const session = Array.isArray(rows) ? rows[0] : null;
  if (!session || new Date(session.expires_at).getTime() <= Date.now()) {
    if (session) await db(`admin_sessions?id=eq.${encodeURIComponent(session.id)}`, { method: 'DELETE' }).catch(() => null);
    throw new ApiError(401, 'Sessão administrativa inválida ou expirada.');
  }
  return session;
}
async function snapshot(request, playerId) {
  const player = await requirePlayer(request, playerId);
  const [credits, withdrawals, bets] = await Promise.all([
    db(`credit_requests?player_id=eq.${playerId}&select=*&order=created_at.desc&limit=10`),
    db(`withdrawal_requests?player_id=eq.${playerId}&select=*&order=created_at.desc&limit=10`),
    db(`bets?player_id=eq.${playerId}&select=*&order=created_at.desc&limit=20`),
  ]);
  const reserved = withdrawals.filter(x => x.status === 'pending').reduce((sum, x) => sum + Number(x.amount), 0);
  return {
    player: playerView(player),
    availableBalance: Math.max(0, Number(player.balance) - reserved),
    reservedBalance: reserved,
    requests: credits.map(x => creditView(x)),
    withdrawals: withdrawals.map(x => withdrawalView(x)),
    bets: bets.map(x => betView(x)),
  };
}
async function adminOverview() {
  const [players, credits, withdrawals, bets, audit] = await Promise.all([
    db('players?select=id,name,phone,balance,blocked,created_at&order=created_at.desc'),
    db('credit_requests?status=eq.pending&select=*&order=created_at.asc'),
    db('withdrawal_requests?status=eq.pending&select=*&order=created_at.asc'),
    db('bets?select=*&order=created_at.desc&limit=200'),
    db('audit_log?select=*&order=created_at.desc&limit=200'),
  ]);
  const names = new Map(players.map(p => [String(p.id), String(p.name)]));
  const numberStats = Array.from({ length: 11 }, (_, number) => {
    const selected = bets.filter(b => Number(b.selected_number) === number);
    return { number, bets: selected.length, staked: selected.reduce((s, b) => s + Number(b.amount), 0) };
  });
  return {
    stats: {
      players: players.length,
      bets: bets.length,
      totalStaked: bets.reduce((s, b) => s + Number(b.amount), 0),
      totalPayout: bets.reduce((s, b) => s + Number(b.payout), 0),
      pendingCredits: credits.length,
      pendingWithdrawals: withdrawals.length,
      reservedCredits: withdrawals.reduce((s, x) => s + Number(x.amount), 0),
    },
    pendingCredits: credits.map(x => creditView(x, names.get(String(x.player_id)) || '—')),
    pendingWithdrawals: withdrawals.map(x => withdrawalView(x, names.get(String(x.player_id)) || '—')),
    numberStats,
    players: players.map(playerView),
    recentBets: bets.slice(0, 100).map(x => betView(x, names.get(String(x.player_id)) || '—')),
    audit: audit.map(x => ({ id: x.id, action: x.action, details: x.details, createdAt: x.created_at })),
  };
}
function normalizePath(request) {
  const pathname = new URL(request.url).pathname;
  for (const marker of ['/functions/v1/jogos-api', '/jogos-api']) {
    const index = pathname.indexOf(marker);
    if (index >= 0) {
      const rest = pathname.slice(index + marker.length);
      return rest || '/';
    }
  }
  return pathname;
}

async function route(request) {
  const path = normalizePath(request);
  const method = request.method.toUpperCase();
  if (method === 'OPTIONS') return noContent();

  if (method === 'GET' && path === '/api/health') return json({ ok: true, game: 'Numero Lendario', mode: 'test' });

  if (method === 'POST' && path === '/api/auth/register') {
    const body = await readJson(request);
    const name = String(body.name || '').trim().slice(0, 60);
    const phone = normalizePhone(body.phone);
    const pin = validPin(body.pin);
    const confirmPin = String(body.confirmPin || '');
    if (!name) throw new ApiError(400, 'Informe o nome.');
    if (!phone) throw new ApiError(400, 'Informe um número de telefone válido.');
    if (!pin) throw new ApiError(400, 'O PIN deve ter de 4 a 8 dígitos.');
    if (pin !== confirmPin) throw new ApiError(400, 'Os PINs não coincidem.');
    const existing = await db(`players?phone=eq.${phone}&select=id&limit=1`);
    if (existing.length) throw new ApiError(409, 'Este número de telefone já está cadastrado.');
    const token = randomToken();
    const rows = await db('players?select=id,name,phone,balance,blocked,created_at', {
      method: 'POST',
      headers: { Prefer: 'return=representation' },
      body: JSON.stringify({
        name,
        phone,
        pin_hash: await sha256(pin),
        secret_hash: await sha256(token),
      }),
    });
    const player = rows[0];
    await db('audit_log', {
      method: 'POST',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ action: 'player.registered', details: { playerId: player.id } }),
    });
    return json({ player: playerView(player), token }, 201);
  }

  if (method === 'POST' && path === '/api/auth/login') {
    const body = await readJson(request);
    const phone = normalizePhone(body.phone);
    const pin = validPin(body.pin);
    if (!phone || !pin) throw new ApiError(400, 'Telefone ou PIN inválido.');
    const pinHash = await sha256(pin);
    const rows = await db(`players?phone=eq.${phone}&pin_hash=eq.${pinHash}&select=id,name,phone,balance,blocked,created_at&limit=1`);
    const player = Array.isArray(rows) ? rows[0] : null;
    if (!player) throw new ApiError(401, 'Telefone ou PIN incorreto.');
    if (player.blocked) throw new ApiError(403, 'Conta bloqueada.');
    const token = randomToken();
    const secretHash = await sha256(token);
    await db(`players?id=eq.${encodeURIComponent(player.id)}`, {
      method: 'PATCH',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ secret_hash: secretHash }),
    });
    return json({ player: playerView(player), token });
  }

  if (method === 'POST' && path === '/api/players') throw new ApiError(410, 'Atualize a página e crie a conta com telefone e PIN.');

  const playerMatch = path.match(/^\/api\/players\/([^/]+)$/);
  if (method === 'GET' && playerMatch) return json(await snapshot(request, decodeURIComponent(playerMatch[1])));

  if (method === 'POST' && path === '/api/credit-requests') {
    const body = await readJson(request);
    const playerId = String(body.playerId || '');
    const value = amount(body.amount);
    const note = String(body.note || '').trim().slice(0, 160);
    if (!value) throw new ApiError(400, 'Valor inválido.');
    const player = await requirePlayer(request, playerId);
    if (player.blocked) throw new ApiError(403, 'Jogador bloqueado.');
    const pending = await db(`credit_requests?player_id=eq.${playerId}&status=eq.pending&select=id&limit=4`);
    if (pending.length >= 3) throw new ApiError(409, 'Existem pedidos pendentes demais.');
    const rows = await db('credit_requests?select=*', {
      method: 'POST',
      headers: { Prefer: 'return=representation' },
      body: JSON.stringify({ player_id: playerId, amount: value, note }),
    });
    return json({ request: creditView(rows[0]) }, 201);
  }

  if (method === 'POST' && path === '/api/withdrawals') {
    const body = await readJson(request);
    const playerId = String(body.playerId || '');
    const value = amount(body.amount);
    if (!value) throw new ApiError(400, 'Valor inválido.');
    await requirePlayer(request, playerId);
    return json({ request: await rpc('jl_request_withdrawal', { p_player_id: playerId, p_amount: value }) }, 201);
  }

  if (method === 'POST' && path === '/api/bets') {
    const body = await readJson(request);
    const playerId = String(body.playerId || '');
    const selected = Number(body.number);
    const value = amount(body.amount);
    if (!Number.isInteger(selected) || selected < 0 || selected > 10) throw new ApiError(400, 'Escolha um número entre 0 e 10.');
    if (!value) throw new ApiError(400, 'Valor da aposta inválido.');
    await requirePlayer(request, playerId);
    const result = await rpc('jl_place_bet', {
      p_player_id: playerId,
      p_selected_number: selected,
      p_amount: value,
      p_drawn_number: secureRandomInt11(),
    });
    return json({ bet: result }, 201);
  }

  if (method === 'POST' && path === '/api/admin/login') {
    const body = await readJson(request);
    const codeHash = await sha256(String(body.code || ''));
    const rows = await db(`admin_config?id=eq.1&code_hash=eq.${codeHash}&select=id&limit=1`);
    if (!rows.length) throw new ApiError(401, 'Código administrativo inválido.');
    const token = randomToken();
    const tokenHash = await sha256(token);
    const expiresAt = new Date(Date.now() + 8 * 60 * 60 * 1000).toISOString();
    await db('admin_sessions', {
      method: 'POST',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ token_hash: tokenHash, expires_at: expiresAt }),
    });
    return json({ token, expiresIn: 28800 });
  }

  if (path.startsWith('/api/admin/')) await requireAdmin(request);

  if (method === 'POST' && path === '/api/admin/logout') {
    const token = adminToken(request);
    if (token) await db(`admin_sessions?token_hash=eq.${await sha256(token)}`, { method: 'DELETE' });
    return noContent();
  }
  if (method === 'GET' && path === '/api/admin/overview') return json(await adminOverview());

  let match = path.match(/^\/api\/admin\/credit-requests\/([^/]+)\/(approve|deny)$/);
  if (method === 'POST' && match) {
    const decision = match[2] === 'approve' ? 'approved' : 'rejected';
    return json({ request: await rpc('jl_review_credit', { p_request_id: decodeURIComponent(match[1]), p_decision: decision }) });
  }
  match = path.match(/^\/api\/admin\/withdrawals\/([^/]+)\/(approve|deny)$/);
  if (method === 'POST' && match) {
    const decision = match[2] === 'approve' ? 'approved' : 'rejected';
    return json({ request: await rpc('jl_review_withdrawal', { p_request_id: decodeURIComponent(match[1]), p_decision: decision }) });
  }
  match = path.match(/^\/api\/admin\/players\/([^/]+)\/(block|unblock)$/);
  if (method === 'POST' && match) return json(await rpc('jl_set_blocked', { p_player_id: decodeURIComponent(match[1]), p_blocked: match[2] === 'block' }));
  match = path.match(/^\/api\/admin\/players\/([^/]+)\/adjust-balance$/);
  if (method === 'POST' && match) {
    const body = await readJson(request);
    const delta = Number(body.delta);
    if (!Number.isFinite(delta) || delta === 0 || Math.abs(delta) > 1000000) throw new ApiError(400, 'Ajuste inválido.');
    return json(await rpc('jl_adjust_balance', { p_player_id: decodeURIComponent(match[1]), p_delta: delta }));
  }

  throw new ApiError(404, 'Rota não encontrada.');
}

Deno.serve(async request => {
  try { return await route(request); }
  catch (error) {
    if (error instanceof ApiError) return json({ error: error.message }, error.status);
    console.error(error);
    return json({ error: 'Erro interno do servidor.' }, 500);
  }
});
