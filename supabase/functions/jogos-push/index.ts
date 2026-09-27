
import 'jsr:@supabase/functions-js/edge-runtime.d.ts'
import * as webpushModule from 'npm:web-push@3.6.7'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const ORIGIN = 'https://jogoslendarios.adadpsf.shop'
const VAPID_PUBLIC = 'BMe98wJexrkusHoSju2gpKCOTfKImcr2WDjXKUX4MtiXHQaK1snhqhRfzy6g7udFNDykoLNhDRQ8nrrZYPUUnQQ'
const webpush: any = (webpushModule as any).default ?? webpushModule

const CORS = {
  'Access-Control-Allow-Origin': ORIGIN,
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-jl-push-secret',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Vary': 'Origin',
}

function out(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json; charset=utf-8' },
  })
}

function fail(message: string, status = 400) {
  return out({ error: message }, status)
}

async function rpc(name: string, args: Record<string, unknown> = {}) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify(args),
  })
  const raw = await response.text()
  let data: any = null
  try { data = raw ? JSON.parse(raw) : null } catch { data = raw }
  if (!response.ok) {
    throw new Error(data?.message || data?.hint || data?.error || `Erro ${response.status}`)
  }
  return data
}

function constantTimeEqual(a: string, b: string) {
  const aa = new TextEncoder().encode(a)
  const bb = new TextEncoder().encode(b)
  let diff = aa.length ^ bb.length
  const n = Math.max(aa.length, bb.length)
  for (let i = 0; i < n; i++) diff |= (aa[i % Math.max(aa.length, 1)] ?? 0) ^ (bb[i % Math.max(bb.length, 1)] ?? 0)
  return diff === 0
}

function routePath(pathname: string) {
  for (const marker of ['/functions/v1/jogos-push', '/jogos-push']) {
    const i = pathname.indexOf(marker)
    if (i >= 0) return pathname.slice(i + marker.length) || '/'
  }
  return pathname
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })

  try {
    const path = routePath(new URL(req.url).pathname)

    if (req.method === 'GET' && path === '/health') {
      return out({ ok: true, service: 'jogos-push' })
    }

    if (req.method === 'GET' && path === '/public-key') {
      return out({ publicKey: VAPID_PUBLIC })
    }

    if (req.method === 'POST' && path === '/subscribe') {
      const body = await req.json().catch(() => ({})) as any
      const token = String(body?.token ?? '')
      const subscription = body?.subscription ?? {}
      const endpoint = String(subscription?.endpoint ?? '')
      const p256dh = String(subscription?.keys?.p256dh ?? '')
      const auth = String(subscription?.keys?.auth ?? '')
      if (!token) return fail('Sessão do jogador ausente.', 401)
      if (!endpoint || !p256dh || !auth) return fail('Subscrição push inválida.')

      const result = await rpc('jl_push_subscribe', {
        p_token: token,
        p_endpoint: endpoint,
        p_p256dh: p256dh,
        p_auth: auth,
        p_user_agent: req.headers.get('user-agent') ?? '',
      })
      return out(result)
    }

    if (req.method === 'POST' && path === '/unsubscribe') {
      const body = await req.json().catch(() => ({})) as any
      const token = String(body?.token ?? '')
      const endpoint = String(body?.endpoint ?? '')
      if (!token) return fail('Sessão do jogador ausente.', 401)
      if (!endpoint) return fail('Endpoint push ausente.')

      const result = await rpc('jl_push_unsubscribe', {
        p_token: token,
        p_endpoint: endpoint,
      })
      return out(result)
    }

    if (req.method === 'POST' && path === '/dispatch') {
      const supplied = req.headers.get('x-jl-push-secret') ?? ''
      const expected = String(await rpc('jl_push_dispatch_secret') ?? '')
      if (!supplied || !expected || !constantTimeEqual(supplied, expected)) {
        return fail('Não autorizado.', 401)
      }

      const body = await req.json().catch(() => ({})) as any
      const notificationId = Number(body?.notification_id)
      if (!Number.isInteger(notificationId) || notificationId < 1) {
        return fail('Notificação inválida.')
      }

      const bundle = await rpc('jl_push_service_bundle', {
        p_notification_id: notificationId,
      })
      if (!bundle?.notification) {
        return out({ ok: true, sent: 0, skipped: true })
      }

      const subscriptions = Array.isArray(bundle.subscriptions) ? bundle.subscriptions : []
      if (!subscriptions.length) {
        await rpc('jl_push_mark_delivery', {
          p_notification_id: notificationId,
          p_sent_count: 0,
          p_invalid_endpoints: [],
        })
        return out({ ok: true, sent: 0 })
      }

      webpush.setVapidDetails(
        'mailto:escolalendaria07@gmail.com',
        String(bundle.vapid_public ?? ''),
        String(bundle.vapid_private ?? ''),
      )

      const notice = bundle.notification
      const payload = JSON.stringify({
        id: String(notice.id ?? `server:${notificationId}`),
        serverId: Number(notice.serverId ?? notificationId),
        title: String(notice.title ?? 'Notificação'),
        message: String(notice.message ?? ''),
        href: String(notice.href ?? './index.html'),
        type: String(notice.type ?? 'info'),
        createdAt: notice.createdAt ?? new Date().toISOString(),
      })

      let sent = 0
      const invalid: string[] = []

      await Promise.all(subscriptions.map(async (sub: any) => {
        try {
          await webpush.sendNotification(sub, payload, {
            TTL: 300,
            urgency: 'high',
          })
          sent += 1
        } catch (error: any) {
          const status = Number(error?.statusCode ?? error?.status ?? 0)
          if (status === 404 || status === 410) invalid.push(String(sub?.endpoint ?? ''))
          else console.error('Web Push delivery failed', status || 'unknown')
        }
      }))

      await rpc('jl_push_mark_delivery', {
        p_notification_id: notificationId,
        p_sent_count: sent,
        p_invalid_endpoints: invalid.filter(Boolean),
      })

      return out({ ok: true, sent, invalid: invalid.length })
    }

    return fail('Rota não encontrada.', 404)
  } catch (error) {
    console.error(error)
    return fail(String((error as Error)?.message || 'Falha no serviço de notificações.'), 500)
  }
})
