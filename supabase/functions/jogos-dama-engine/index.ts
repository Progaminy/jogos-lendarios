import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { analyze } from "./engine-verified.js";

const ORIGIN = "https://jogoslendarios.adadpsf.shop";
const HEADERS = {
  "Access-Control-Allow-Origin": ORIGIN,
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
  "Vary": "Origin"
};

function respond(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), { status, headers: HEADERS });
}

async function rpc(req: Request, name: string, args: unknown) {
  const url = Deno.env.get("SUPABASE_URL") || "";
  const apikey = req.headers.get("apikey") || "";
  const authorization = req.headers.get("authorization") || `Bearer ${apikey}`;
  if (!url || !apikey) throw new Error("EDGE_CONFIG_MISSING");

  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey,
      authorization,
      "Content-Type": "application/json",
      Accept: "application/json"
    },
    body: JSON.stringify(args)
  });

  const raw = await response.text();
  let payload: any = null;
  try { payload = raw ? JSON.parse(raw) : null; } catch { payload = raw; }
  if (!response.ok) throw new Error(payload?.message || payload?.error || payload?.hint || `RPC_${response.status}`);
  return payload;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: HEADERS });
  if (req.method !== "POST") return respond({ error: "METHOD_NOT_ALLOWED" }, 405);

  const origin = req.headers.get("origin");
  if (origin && origin !== ORIGIN) return respond({ error: "ORIGIN_NOT_ALLOWED" }, 403);

  let body: any = null;
  try { body = await req.json(); } catch { return respond({ error: "INVALID_JSON" }, 400); }

  const token = String(body?.token || "").trim();
  const roomId = String(body?.room_id || "").trim();
  if (!token || !roomId || token.length > 256 || roomId.length > 64) {
    return respond({ error: "INVALID_REQUEST" }, 400);
  }

  try {
    const context = await rpc(req, "jl_dama_analysis_context", {
      p_token: token,
      p_room: roomId
    });
    if (!context?.enabled) return respond({ error: context?.reason || "NOT_ALLOWED" }, 403);

    const snapshot = await rpc(req, "jl_dama_room_state", {
      p_token: token,
      p_room: roomId
    });
    if (snapshot?.room?.current_player_id !== snapshot?.identity?.player_id) {
      return respond({ error: "NOT_YOUR_TURN" }, 409);
    }
    if (!Array.isArray(snapshot?.legal_moves) || snapshot.legal_moves.length === 0) {
      return respond({ error: "NO_LEGAL_MOVES" }, 404);
    }

    snapshot.analysis_context = context;
    const hint = analyze(snapshot);
    return respond({ ok: true, hint });
  } catch (error) {
    console.error("jogos-dama-engine", error);
    return respond({ error: "ENGINE_ERROR" }, 500);
  }
});
