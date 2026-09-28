const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, x-player-token',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
};
const HEAD = {
  ...CORS,
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff'
};

class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: HEAD });

const noContent = () => new Response(null, { status: 204, headers: CORS });

async function body(req) {
  try {
    return await req.json();
  } catch {
    throw new ApiError(400, 'JSON inválido.');
  }
}

function env() {
  const url = Deno.env.get('SUPABASE_URL') || '';
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!url || !key) throw new ApiError(500, 'Configuração do servidor incompleta.');
  return { url, key };
}

function mapDb(msg) {
  const pairs = [
    ['ROUND_ACTIVE', 409, 'Já existe uma rodada em andamento.'],
    ['ROUND_NOT_OPEN', 409, 'As apostas não estão abertas.'],
    ['ROUND_CLOSED', 409, 'As apostas desta rodada estão fechadas.'],
    ['ROUND_NOT_CLOSED', 409, 'Feche as apostas antes de sortear.'],
    ['RESULT_ALREADY_DRAWN', 409, 'O número desta rodada já foi sorteado e está bloqueado.'],
    ['ROUND_NOT_DRAWN', 409, 'É preciso sortear o número antes de publicar.'],
    ['ROUND_ENGINE_REQUIRED', 409, 'Esta aposta deve usar o sistema de rodadas.'],
    ['INVALID_TIMER', 400, 'Defina um horário de encerramento futuro, no máximo 24 horas à frente.'],
    ['INVALID_NUMBER', 400, 'Número inválido.'],
    ['INVALID_AMOUNT', 400, 'Valor inválido.'],
    ['PLAYER_NOT_FOUND', 404, 'Conta não encontrada.'],
    ['PLAYER_BLOCKED', 403, 'Conta bloqueada.'],
    ['INSUFFICIENT_AVAILABLE_BALANCE', 409, 'Saldo disponível insuficiente.']
  ];
  for (const [needle, status, message] of pairs) {
    if (msg.includes(needle)) return new ApiError(status, message);
  }
  return new ApiError(500, 'Não foi possível concluir a operação.');
}

async function db(path, options = {}) {
  const { url, key } = env();
  const r = await fetch(`${url.replace(/\/$/, '')}/rest/v1/${path}`, {
    ...options,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...(options.headers || {})
    }
  });
  const text = await r.text();
  let data = null;
  if (text) {
    try { data = JSON.parse(text); } catch { data = text; }
  }
  if (!r.ok) {
    const msg = data && typeof data === 'object'
      ? String(data.message || data.error || data.details || text)
      : text;
    throw mapDb(msg);
  }
  return data;
}

async function rpc(name, payload = {}) {
  return await db(`rpc/${name}`, {
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify(payload)
  });
}

function hex(bytes) {
  return [...bytes].map(b => b.toString(16).padStart(2, '0')).join('');
}

async function sha256(v) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(String(v)));
  return hex(new Uint8Array(d));
}

function adminBearer(req) {
  const a = req.headers.get('Authorization') || '';
  return a.startsWith('Bearer ') ? a.slice(7) : '';
}

async function requireAdmin(req) {
  const token = adminBearer(req);
  if (!token) throw new ApiError(401, 'Sessão administrativa inválida ou expirada.');
  const h = await sha256(token);
  const rows = await db(`admin_sessions?token_hash=eq.${h}&select=id,expires_at&limit=1`);
  const s = Array.isArray(rows) ? rows[0] : null;
  if (!s || new Date(s.expires_at).getTime() <= Date.now()) {
    throw new ApiError(401, 'Sessão administrativa inválida ou expirada.');
  }
  return s;
}

async function requirePlayer(req, playerId) {
  const token = req.headers.get('X-Player-Token') || '';
  if (!token) throw new ApiError(401, 'Sessão do jogador inválida.');
  const h = await sha256(token);
  const rows = await db(
    `players?id=eq.${encodeURIComponent(playerId)}&secret_hash=eq.${h}&select=id,name,balance,blocked&limit=1`
  );
  const p = Array.isArray(rows) ? rows[0] : null;
  if (!p) throw new ApiError(401, 'Sessão do jogador inválida.');
  if (p.blocked) throw new ApiError(403, 'Conta bloqueada.');
  return p;
}

function secureRandomInt11() {
  const range = 2 ** 32;
  const limit = Math.floor(range / 11) * 11;
  const a = new Uint32Array(1);
  do crypto.getRandomValues(a); while (a[0] >= limit);
  return a[0] % 11;
}

function normalizePath(req) {
  const p = new URL(req.url).pathname;
  for (const marker of ['/functions/v1/jogos-rounds', '/jogos-rounds']) {
    const i = p.indexOf(marker);
    if (i >= 0) {
      const rest = p.slice(i + marker.length);
      return rest || '/';
    }
  }
  return p;
}

async function latestRound() {
  const rows = await db('game_rounds?select=*&order=opened_at.desc&limit=1');
  let r = Array.isArray(rows) ? rows[0] : null;
  if (
    r &&
    r.status === 'open' &&
    r.closes_at &&
    new Date(r.closes_at).getTime() <= Date.now()
  ) {
    await db(`game_rounds?id=eq.${r.id}&status=eq.open`, {
      method: 'PATCH',
      headers: { Prefer: 'return=representation' },
      body: JSON.stringify({
        status: 'closed',
        closed_at: new Date().toISOString()
      })
    });
    const again = await db(`game_rounds?id=eq.${r.id}&select=*&limit=1`);
    r = again[0] || r;
  }
  return r;
}

function roundView(r, admin = false) {
  if (!r) return null;
  return {
    id: r.id,
    status: r.status,
    openedAt: r.opened_at,
    closesAt: r.closes_at,
    closedAt: r.closed_at,
    drawnNumber: (admin || r.status === 'published') ? r.drawn_number : null,
    drawnAt: (admin || r.status === 'published') ? r.drawn_at : null,
    publishedAt: r.published_at
  };
}

async function roundStats(r) {
  if (!r) {
    return {
      numberStats: Array.from({ length: 11 }, (_, number) => ({ number, bets: 0, staked: 0 })),
      bets: 0,
      totalStaked: 0,
      winners: []
    };
  }
  const bets = await db(
    `bets?round_id=eq.${r.id}&select=id,player_id,selected_number,amount,won,payout,created_at&order=created_at.desc`
  );
  const stats = Array.from({ length: 11 }, (_, number) => {
    const chosen = bets.filter(b => Number(b.selected_number) === number);
    return {
      number,
      bets: chosen.length,
      staked: chosen.reduce((s, b) => s + Number(b.amount), 0)
    };
  });

  let winners = [];
  if (r.status === 'published') {
    const won = bets.filter(b => b.won === true);
    const ids = [...new Set(won.map(b => b.player_id))];
    let names = new Map();
    if (ids.length) {
      const players = await db(`players?id=in.(${ids.join(',')})&select=id,name`);
      names = new Map(players.map(p => [String(p.id), String(p.name)]));
    }
    winners = won.map(b => ({
      playerId: b.player_id,
      playerName: names.get(String(b.player_id)) || 'Jogador',
      amount: Number(b.amount),
      payout: Number(b.payout)
    }));
  }

  return {
    numberStats: stats,
    bets: bets.length,
    totalStaked: bets.reduce((s, b) => s + Number(b.amount), 0),
    winners
  };
}

async function route(req) {
  const path = normalizePath(req);
  const method = req.method.toUpperCase();

  if (method === 'OPTIONS') return noContent();

  if (method === 'GET' && path === '/api/game-state') {
    const r = await latestRound();
    return json({ round: roundView(r, false) });
  }

  if (method === 'POST' && path === '/api/round-bets') {
    const b = await body(req);
    const playerId = String(b.playerId || '');
    await requirePlayer(req, playerId);
    const result = await rpc('jl_place_round_bet', {
      p_player_id: playerId,
      p_selected_number: Number(b.number),
      p_amount: Number(b.amount)
    });
    return json({ bet: result }, 201);
  }

  if (path.startsWith('/api/admin/')) await requireAdmin(req);

  if (method === 'GET' && path === '/api/admin/round-state') {
    const r = await latestRound();
    const stats = await roundStats(r);
    return json({ round: roundView(r, true), ...stats });
  }

  if (method === 'POST' && path === '/api/admin/rounds/open') {
    const b = await body(req);
    if (b.closesAt) {
      const closesAt = new Date(String(b.closesAt));
      if (Number.isNaN(closesAt.getTime())) {
        throw new ApiError(400, 'Horário de encerramento inválido.');
      }
      return json({
        round: await rpc('jl_open_round_at', { p_closes_at: closesAt.toISOString() })
      }, 201);
    }

    const raw = b.minutes;
    const minutes = raw === null || raw === '' || raw === undefined ? null : Number(raw);
    return json({
      round: await rpc('jl_open_round', { p_minutes: minutes })
    }, 201);
  }

  if (method === 'POST' && path === '/api/admin/rounds/close') {
    return json({ round: await rpc('jl_close_round') });
  }

  if (method === 'POST' && path === '/api/admin/rounds/draw') {
    const n = secureRandomInt11();
    return json({ round: await rpc('jl_draw_round', { p_drawn_number: n }) });
  }

  if (method === 'POST' && path === '/api/admin/rounds/publish') {
    return json({ round: await rpc('jl_publish_round') });
  }

  throw new ApiError(404, 'Rota não encontrada.');
}

Deno.serve(async req => {
  try {
    return await route(req);
  } catch (e) {
    if (e instanceof ApiError) return json({ error: e.message }, e.status);
    console.error(e);
    return json({ error: 'Erro interno do servidor.' }, 500);
  }
});
