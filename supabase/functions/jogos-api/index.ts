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
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: JSON_HEADERS });
}

function noContent(status = 204) {
  return new Response(null, { status, headers: { ...CORS_HEADERS, 'Cache-Control': 'no-store' } });
}

async function readJson(request: Request) {
  try {
    return await request.json();
  } catch {
    throw new ApiError(400, 'JSON inválido.');
  }
}

function runtimeEnv() {
  const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
  const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new ApiError(500, 'Configuração do servidor incompleta.');
  }
  return { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY };
}

function serviceHeaders(extra: Record<string, string> = {}) {
  const env = runtimeEnv();
  return {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    ...extra,
  };
}

async function supabase(path: string, options: RequestInit = {}) {
  const env = runtimeEnv();
  const url = `${env.SUPABASE_URL.replace(/\/$/, '')}/rest/v1/${path}`;
  const response = await fetch(url, {
    ...options,
    headers: {
      ...serviceHeaders(),
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...((options.headers || {}) as Record<string, string>),
    },
  });

  const text = await response.text();
  let data: unknown = null;
  if (text) {
    try { data = JSON.parse(text); } catch { data = text; }
  }

  if (!response.ok) {
    const obj = data && typeof data === 'object' ? data as Record<string, unknown> : null;
    const message = obj ? String(obj.message || obj.error || obj.details || '') : text;
    throw mapDatabaseError(message || 'Erro de banco de dados.');
  }
  return data;
}

function mapDatabaseError(message: string) {
  const text = String(message || '');
  const map: Array<[string, [number, string]]> = [
    ['PLAYER_NOT_FOUND', [404, 'Jogador não encontrado.']],
    ['PLAYER_BLOCKED', [403, 'Jogador bloqueado.']],
    ['INVALID_NUMBER', [400, 'Escolha um número inteiro entre 0 e 10.']],
    ['INVALID_AMOUNT', [400, 'Valor inválido.']],
    ['INSUFFICIENT_AVAILABLE_BALANCE', [409, 'Saldo disponível insuficiente. Há MTS de demonstração reservados ou o saldo é menor que o valor pedido.']],
    ['INSUFFICIENT_BALANCE', [409, 'Saldo insuficiente para concluir a aprovação.']],
    ['REQUEST_NOT_FOUND', [404, 'Pedido não encontrado.']],
    ['REQUEST_ALREADY_REVIEWED', [409, 'Este pedido já foi analisado.']],
    ['RESERVED_BALANCE_CONFLICT', [409, 'O ajuste conflita com MTS de demonstração reservados em levantamentos pendentes.']],
    ['INVALID_DECISION', [400, 'Decisão inválida.']],
  ];
  for (const [needle, [status, friendly]] of map) {
    if (text.includes(needle)) return new ApiError(status, friendly);
  }
  return new ApiError(500, 'Não foi possível concluir a operação no banco.');
}

function hex(bytes: Uint8Array) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function sha256(value: unknown) {
  const bytes = new TextEncoder().encode(String(value));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return hex(new Uint8Array(digest));
}

function randomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return hex(bytes);
}

function adminBearer(request: Request) {
  const auth = request.headers.get('Authorization') || '';
  return auth.startsWith('Bearer ') ? auth.slice(7) : '';
}

async function requireAdmin(request: Request) {
  const token = adminBearer(request);
  if (!token) throw new ApiError(401, 'Sessão administrativa inválida ou expirada.');
  const tokenHash = await sha256(token);
  const rows = await supabase(`admin_sessions?token_hash=eq.${tokenHash}&select=id,expires_at&limit=1`) as Array<{ id: string; expires_at: string }>;
  const session = Array.isArray(rows) ? rows[0] : null;
  if (!session || new Date(session.expires_at).getTime() <= Date.now()) {
    if (session) await supabase(`admin_sessions?id=eq.${encodeURIComponent(session.id)}`, { method: 'DELETE' }).catch(() => null);
    throw new ApiError(401, 'Sessão administrativa inválida ou expirada.');
  }
  return { tokenHash, session };
}

async function requirePlayer(request: Request, playerId: string) {
  const token = request.headers.get('X-Player-Token') || '';
  if (!token) throw new ApiError(401, 'Sessão do jogador inválida.');
  const secretHash = await sha256(token);
  const rows = await supabase(
    `players?id=eq.${encodeURIComponent(playerId)}&secret_hash=eq.${secretHash}&select=id,name,balance,blocked,created_at&limit=1`,
  ) as Array<Record<string, unknown>>;
  const player = Array.isArray(rows) ? rows[0] : null;
  if (!player) throw new ApiError(401, 'Sessão do jogador inválida.');
  return player;
}

function amount(value: unknown) {
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

function messageText(value: unknown) {
  const text = String(value || '').trim();
  if (!text || text.length > 1000) return null;
  return text;
}

function playerView(row: Record<string, unknown>) {
  return {
    id: row.id,
    name: row.name,
    balance: Number(row.balance),
    blocked: Boolean(row.blocked),
    createdAt: row.created_at,
  };
}

function creditView(row: Record<string, unknown>, playerName = '') {
  return {
    id: row.id,
    playerId: row.player_id,
    playerName,
    amount: Number(row.amount),
    note: row.note || '',
    status: row.status,
    createdAt: row.created_at,
    reviewedAt: row.reviewed_at,
  };
}

function withdrawalView(row: Record<string, unknown>, playerName = '') {
  return {
    id: row.id,
    playerId: row.player_id,
    playerName,
    amount: Number(row.amount),
    status: row.status,
    createdAt: row.created_at,
    reviewedAt: row.reviewed_at,
  };
}

function betView(row: Record<string, unknown>, playerName = '') {
  return {
    id: row.id,
    playerId: row.player_id,
    playerName,
    selectedNumber: row.selected_number,
    drawnNumber: row.drawn_number,
    amount: Number(row.amount),
    won: Boolean(row.won),
    payout: Number(row.payout),
    createdAt: row.created_at,
  };
}

function messageView(row: Record<string, unknown>, playerName = '') {
  return {
    id: row.id,
    playerId: row.player_id,
    playerName,
    sender: row.sender_role,
    body: row.body,
    createdAt: row.created_at,
  };
}

async function rpc(name: string, body: Record<string, unknown>) {
  return await supabase(`rpc/${name}`, {
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify(body),
  });
}

async function playerSnapshot(request: Request, playerId: string) {
  const player = await requirePlayer(request, playerId);
  const [credits, withdrawals, bets, messagesDesc] = await Promise.all([
    supabase(`credit_requests?player_id=eq.${playerId}&select=*&order=created_at.desc&limit=10`) as Promise<Array<Record<string, unknown>>>,
    supabase(`withdrawal_requests?player_id=eq.${playerId}&select=*&order=created_at.desc&limit=10`) as Promise<Array<Record<string, unknown>>>,
    supabase(`bets?player_id=eq.${playerId}&select=*&order=created_at.desc&limit=20`) as Promise<Array<Record<string, unknown>>>,
    supabase(`messages?player_id=eq.${playerId}&select=*&order=created_at.desc&limit=100`) as Promise<Array<Record<string, unknown>>>,
  ]);
  const reserved = withdrawals.filter((item) => item.status === 'pending').reduce((sum, item) => sum + Number(item.amount), 0);
  return {
    player: playerView(player),
    availableBalance: Math.max(0, Number(player.balance) - reserved),
    reservedBalance: reserved,
    requests: credits.map((row) => creditView(row)),
    withdrawals: withdrawals.map((row) => withdrawalView(row)),
    bets: bets.map((row) => betView(row)),
    messages: messagesDesc.reverse().map((row) => messageView(row)),
  };
}

async function adminOverview() {
  const [players, deposits, withdrawals, bets, audit, messages] = await Promise.all([
    supabase('players?select=id,name,balance,blocked,created_at&order=created_at.desc') as Promise<Array<Record<string, unknown>>>,
    supabase('credit_requests?status=eq.pending&select=*&order=created_at.asc') as Promise<Array<Record<string, unknown>>>,
    supabase('withdrawal_requests?status=eq.pending&select=*&order=created_at.asc') as Promise<Array<Record<string, unknown>>>,
    supabase('bets?select=*&order=created_at.desc&limit=200') as Promise<Array<Record<string, unknown>>>,
    supabase('audit_log?select=*&order=created_at.desc&limit=200') as Promise<Array<Record<string, unknown>>>,
    supabase('messages?select=*&order=created_at.desc&limit=300') as Promise<Array<Record<string, unknown>>>,
  ]);

  const names = new Map(players.map((player) => [String(player.id), String(player.name)]));
  const totalStaked = bets.reduce((sum, bet) => sum + Number(bet.amount), 0);
  const totalPayout = bets.reduce((sum, bet) => sum + Number(bet.payout), 0);
  const numberStats = Array.from({ length: 11 }, (_, number) => {
    const selected = bets.filter((bet) => Number(bet.selected_number) === number);
    return { number, bets: selected.length, staked: selected.reduce((sum, bet) => sum + Number(bet.amount), 0) };
  });

  return {
    stats: {
      players: players.length,
      bets: bets.length,
      totalStaked,
      totalPayout,
      pendingCredits: deposits.length,
      pendingWithdrawals: withdrawals.length,
      reservedCredits: withdrawals.reduce((sum, item) => sum + Number(item.amount), 0),
      messages: messages.length,
    },
    pendingCredits: deposits.map((row) => creditView(row, names.get(String(row.player_id)) || '—')),
    pendingWithdrawals: withdrawals.map((row) => withdrawalView(row, names.get(String(row.player_id)) || '—')),
    numberStats,
    players: players.map(playerView),
    recentBets: bets.slice(0, 100).map((row) => betView(row, names.get(String(row.player_id)) || '—')),
    messages: messages.reverse().map((row) => messageView(row, names.get(String(row.player_id)) || '—')),
    audit: audit.map((item) => ({ id: item.id, action: item.action, details: item.details, createdAt: item.created_at })),
  };
}

function normalizePath(request: Request) {
  const pathname = new URL(request.url).pathname;
  const prefix = '/functions/v1/jogos-api';
  if (pathname.startsWith(prefix)) return pathname.slice(prefix.length) || '/';
  return pathname;
}

async function route(request: Request) {
  const path = normalizePath(request);
  const method = request.method.toUpperCase();

  if (method === 'OPTIONS') return noContent();

  if (method === 'GET' && path === '/api/health') {
    return json({ ok: true, game: 'Numero Lendario', mode: 'mts-demo', platform: 'cloudflare-supabase-edge', messaging: true });
  }

  if (method === 'POST' && path === '/api/players') {
    const body = await readJson(request) as Record<string, unknown>;
    const name = String(body.name || '').trim().slice(0, 60);
    if (!name) throw new ApiError(400, 'Informe o nome do jogador.');
    const token = randomToken();
    const secretHash = await sha256(token);
    const rows = await supabase('players?select=id,name,balance,blocked,created_at', {
      method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ name, secret_hash: secretHash }),
    }) as Array<Record<string, unknown>>;
    const player = rows[0];
    await supabase('audit_log', {
      method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ action: 'player.created', details: { playerId: player.id, name } }),
    });
    return json({ player: playerView(player), token }, 201);
  }

  const playerMatch = path.match(/^\/api\/players\/([^/]+)$/);
  if (method === 'GET' && playerMatch) return json(await playerSnapshot(request, decodeURIComponent(playerMatch[1])));

  const messageMatch = path.match(/^\/api\/messages\/([^/]+)$/);
  if (messageMatch && method === 'GET') {
    const playerId = decodeURIComponent(messageMatch[1]);
    await requirePlayer(request, playerId);
    const rows = await supabase(`messages?player_id=eq.${playerId}&select=*&order=created_at.desc&limit=100`) as Array<Record<string, unknown>>;
    return json({ messages: rows.reverse().map((row) => messageView(row)) });
  }
  if (messageMatch && method === 'POST') {
    const playerId = decodeURIComponent(messageMatch[1]);
    const player = await requirePlayer(request, playerId);
    if (player.blocked) throw new ApiError(403, 'Jogador bloqueado.');
    const body = await readJson(request) as Record<string, unknown>;
    const text = messageText(body.message);
    if (!text) throw new ApiError(400, 'A mensagem deve ter entre 1 e 1000 caracteres.');
    const rows = await supabase('messages?select=*', {
      method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ player_id: playerId, sender_role: 'player', body: text }),
    }) as Array<Record<string, unknown>>;
    return json({ message: messageView(rows[0]) }, 201);
  }

  if (method === 'POST' && path === '/api/credit-requests') {
    const body = await readJson(request) as Record<string, unknown>;
    const playerId = String(body.playerId || '');
    const value = amount(body.amount);
    const note = String(body.note || '').trim().slice(0, 160);
    if (!value) throw new ApiError(400, 'Valor inválido.');
    const player = await requirePlayer(request, playerId);
    if (player.blocked) throw new ApiError(403, 'Jogador bloqueado.');
    const pending = await supabase(`credit_requests?player_id=eq.${playerId}&status=eq.pending&select=id&limit=4`) as Array<unknown>;
    if (pending.length >= 3) throw new ApiError(409, 'Existem pedidos pendentes demais para este jogador.');
    const rows = await supabase('credit_requests?select=*', {
      method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ player_id: playerId, amount: value, note }),
    }) as Array<Record<string, unknown>>;
    const item = rows[0];
    await supabase('audit_log', {
      method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ action: 'deposit.requested', details: { requestId: item.id, playerId, amount: value } }),
    });
    return json({ request: creditView(item) }, 201);
  }

  if (method === 'POST' && path === '/api/withdrawals') {
    const body = await readJson(request) as Record<string, unknown>;
    const playerId = String(body.playerId || '');
    const value = amount(body.amount);
    if (!value) throw new ApiError(400, 'Valor de levantamento inválido.');
    await requirePlayer(request, playerId);
    const result = await rpc('jl_request_withdrawal', { p_player_id: playerId, p_amount: value });
    return json({ request: result }, 201);
  }

  if (method === 'POST' && path === '/api/bets') {
    const body = await readJson(request) as Record<string, unknown>;
    const playerId = String(body.playerId || '');
    const selected = Number(body.number);
    const value = amount(body.amount);
    if (!Number.isInteger(selected) || selected < 0 || selected > 10) throw new ApiError(400, 'Escolha um número inteiro entre 0 e 10.');
    if (!value) throw new ApiError(400, 'Valor da aposta inválido.');
    await requirePlayer(request, playerId);
    const drawn = secureRandomInt11();
    const result = await rpc('jl_place_bet', { p_player_id: playerId, p_selected_number: selected, p_amount: value, p_drawn_number: drawn });
    return json({ bet: result }, 201);
  }

  if (method === 'POST' && path === '/api/admin/login') {
    const body = await readJson(request) as Record<string, unknown>;
    const codeHash = await sha256(String(body.code || ''));
    const matches = await supabase(`admin_config?id=eq.1&code_hash=eq.${codeHash}&select=id&limit=1`) as Array<unknown>;
    if (!matches.length) throw new ApiError(401, 'Código administrativo inválido.');
    const token = randomToken();
    const tokenHash = await sha256(token);
    const expiresAt = new Date(Date.now() + 8 * 60 * 60 * 1000).toISOString();
    await supabase('admin_sessions', {
      method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ token_hash: tokenHash, expires_at: expiresAt }),
    });
    return json({ token, expiresIn: 28800 });
  }

  if (path.startsWith('/api/admin/')) await requireAdmin(request);

  if (method === 'POST' && path === '/api/admin/logout') {
    const token = adminBearer(request);
    if (token) {
      const tokenHash = await sha256(token);
      await supabase(`admin_sessions?token_hash=eq.${tokenHash}`, { method: 'DELETE' });
    }
    return noContent();
  }

  if (method === 'GET' && path === '/api/admin/overview') return json(await adminOverview());

  const adminMessageMatch = path.match(/^\/api\/admin\/messages\/([^/]+)$/);
  if (method === 'POST' && adminMessageMatch) {
    const playerId = decodeURIComponent(adminMessageMatch[1]);
    const playerRows = await supabase(`players?id=eq.${encodeURIComponent(playerId)}&select=id,name&limit=1`) as Array<Record<string, unknown>>;
    if (!playerRows.length) throw new ApiError(404, 'Jogador não encontrado.');
    const body = await readJson(request) as Record<string, unknown>;
    const text = messageText(body.message);
    if (!text) throw new ApiError(400, 'A mensagem deve ter entre 1 e 1000 caracteres.');
    const rows = await supabase('messages?select=*', {
      method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ player_id: playerId, sender_role: 'admin', body: text }),
    }) as Array<Record<string, unknown>>;
    return json({ message: messageView(rows[0], String(playerRows[0].name || '')) }, 201);
  }

  const creditReview = path.match(/^\/api\/admin\/credit-requests\/([^/]+)\/(approve|deny)$/);
  if (method === 'POST' && creditReview) {
    const decision = creditReview[2] === 'approve' ? 'approved' : 'rejected';
    const result = await rpc('jl_review_credit', { p_request_id: decodeURIComponent(creditReview[1]), p_decision: decision });
    return json({ request: result });
  }

  const withdrawalReview = path.match(/^\/api\/admin\/withdrawals\/([^/]+)\/(approve|deny)$/);
  if (method === 'POST' && withdrawalReview) {
    const decision = withdrawalReview[2] === 'approve' ? 'approved' : 'rejected';
    const result = await rpc('jl_review_withdrawal', { p_request_id: decodeURIComponent(withdrawalReview[1]), p_decision: decision });
    return json({ request: result });
  }

  const blockMatch = path.match(/^\/api\/admin\/players\/([^/]+)\/(block|unblock)$/);
  if (method === 'POST' && blockMatch) {
    const result = await rpc('jl_set_blocked', { p_player_id: decodeURIComponent(blockMatch[1]), p_blocked: blockMatch[2] === 'block' });
    return json(result);
  }

  const adjustMatch = path.match(/^\/api\/admin\/players\/([^/]+)\/adjust-balance$/);
  if (method === 'POST' && adjustMatch) {
    const body = await readJson(request) as Record<string, unknown>;
    const delta = Number(body.delta);
    if (!Number.isFinite(delta) || delta === 0 || Math.abs(delta) > 1000000) throw new ApiError(400, 'Ajuste inválido.');
    const result = await rpc('jl_adjust_balance', { p_player_id: decodeURIComponent(adjustMatch[1]), p_delta: delta });
    return json(result);
  }

  throw new ApiError(404, 'Rota não encontrada.');
}

Deno.serve(async (request: Request) => {
  try {
    return await route(request);
  } catch (error) {
    if (error instanceof ApiError) return json({ error: error.message }, error.status);
    console.error(error);
    return json({ error: 'Erro interno do servidor.' }, 500);
  }
});