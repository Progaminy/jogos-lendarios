const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, x-player-token',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

function env() {
  const url = Deno.env.get('SUPABASE_URL') || '';
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!url || !key) throw new ApiError(500, 'Configuração do servidor incompleta.');
  return { url, key };
}

async function db(path: string, options: RequestInit = {}) {
  const { url, key } = env();
  const response = await fetch(`${url.replace(/\/$/, '')}/rest/v1/${path}`, {
    ...options,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...((options.headers || {}) as Record<string, string>),
    },
  });
  const text = await response.text();
  let data: unknown = null;
  if (text) {
    try { data = JSON.parse(text); } catch { data = text; }
  }
  if (!response.ok) throw new ApiError(response.status >= 400 && response.status < 500 ? response.status : 500, 'Não foi possível concluir a operação.');
  return data;
}

function hex(bytes: Uint8Array) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function sha256(value: unknown) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(String(value)));
  return hex(new Uint8Array(digest));
}

async function requirePlayer(request: Request, playerId: string) {
  const token = request.headers.get('X-Player-Token') || '';
  if (!token) throw new ApiError(401, 'Sessão do jogador inválida.');
  const hash = await sha256(token);
  const rows = await db(`players?id=eq.${encodeURIComponent(playerId)}&secret_hash=eq.${hash}&select=id,name,blocked&limit=1`) as Array<Record<string, unknown>>;
  if (!rows.length) throw new ApiError(401, 'Sessão do jogador inválida.');
  return rows[0];
}

async function requireAdmin(request: Request) {
  const auth = request.headers.get('Authorization') || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!token) throw new ApiError(401, 'Sessão administrativa inválida ou expirada.');
  const hash = await sha256(token);
  const rows = await db(`admin_sessions?token_hash=eq.${hash}&select=id,expires_at&limit=1`) as Array<Record<string, unknown>>;
  if (!rows.length || new Date(String(rows[0].expires_at)).getTime() <= Date.now()) {
    throw new ApiError(401, 'Sessão administrativa inválida ou expirada.');
  }
}

function cleanMessage(value: unknown) {
  const text = String(value || '').trim();
  if (!text || text.length > 1000) throw new ApiError(400, 'A mensagem deve ter entre 1 e 1000 caracteres.');
  return text;
}

function view(row: Record<string, unknown>, playerName = '') {
  return {
    id: row.id,
    playerId: row.player_id,
    playerName,
    sender: row.sender_role,
    body: row.body,
    createdAt: row.created_at,
  };
}

function pathOf(request: Request) {
  const pathname = new URL(request.url).pathname;
  const prefix = '/functions/v1/jogos-messages';
  return pathname.startsWith(prefix) ? pathname.slice(prefix.length) || '/' : pathname;
}

Deno.serve(async (request: Request) => {
  try {
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
    const path = pathOf(request);
    const method = request.method.toUpperCase();

    if (method === 'GET' && path === '/api/health') return json({ ok: true, messaging: true });

    const playerMatch = path.match(/^\/api\/messages\/([^/]+)$/);
    if (playerMatch) {
      const playerId = decodeURIComponent(playerMatch[1]);
      const player = await requirePlayer(request, playerId);
      if (method === 'GET') {
        const rows = await db(`messages?player_id=eq.${encodeURIComponent(playerId)}&select=*&order=created_at.desc&limit=100`) as Array<Record<string, unknown>>;
        return json({ messages: rows.reverse().map((row) => view(row)) });
      }
      if (method === 'POST') {
        if (player.blocked) throw new ApiError(403, 'Jogador bloqueado.');
        const body = await request.json().catch(() => ({})) as Record<string, unknown>;
        const message = cleanMessage(body.message);
        const rows = await db('messages?select=*', {
          method: 'POST',
          headers: { Prefer: 'return=representation' },
          body: JSON.stringify({ player_id: playerId, sender_role: 'player', body: message }),
        }) as Array<Record<string, unknown>>;
        return json({ message: view(rows[0]) }, 201);
      }
    }

    if (path.startsWith('/api/admin/')) await requireAdmin(request);

    if (method === 'GET' && path === '/api/admin/messages') {
      const [players, messages] = await Promise.all([
        db('players?select=id,name&order=created_at.desc') as Promise<Array<Record<string, unknown>>>,
        db('messages?select=*&order=created_at.desc&limit=300') as Promise<Array<Record<string, unknown>>>,
      ]);
      const names = new Map(players.map((p) => [String(p.id), String(p.name)]));
      return json({ messages: messages.reverse().map((row) => view(row, names.get(String(row.player_id)) || '—')) });
    }

    const adminReply = path.match(/^\/api\/admin\/messages\/([^/]+)$/);
    if (method === 'POST' && adminReply) {
      const playerId = decodeURIComponent(adminReply[1]);
      const players = await db(`players?id=eq.${encodeURIComponent(playerId)}&select=id,name&limit=1`) as Array<Record<string, unknown>>;
      if (!players.length) throw new ApiError(404, 'Jogador não encontrado.');
      const body = await request.json().catch(() => ({})) as Record<string, unknown>;
      const message = cleanMessage(body.message);
      const rows = await db('messages?select=*', {
        method: 'POST',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ player_id: playerId, sender_role: 'admin', body: message }),
      }) as Array<Record<string, unknown>>;
      return json({ message: view(rows[0], String(players[0].name || '')) }, 201);
    }

    throw new ApiError(404, 'Rota não encontrada.');
  } catch (error) {
    if (error instanceof ApiError) return json({ error: error.message }, error.status);
    console.error(error);
    return json({ error: 'Erro interno do servidor.' }, 500);
  }
});