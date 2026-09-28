import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const ORIGIN = "https://jogoslendarios.adadpsf.shop";
const HEADERS = {
  "Access-Control-Allow-Origin": ORIGIN,
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
  "Vary": "Origin",
};

Deno.serve((req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: HEADERS });
  }

  return new Response(JSON.stringify({
    error: "EDGE_FUNCTION_DISABLED",
    message: "Esta função legada foi desativada."
  }), {
    status: 410,
    headers: HEADERS
  });
});
