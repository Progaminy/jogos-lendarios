import http from 'k6/http';
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const PROJECT = __ENV.SUPABASE_PROJECT || 'bxndjyzghgrmkelshtdp';
const API_KEY = __ENV.SUPABASE_ANON_KEY || 'sb_publishable_E-Uikud2p7M6-dgcCK5ttg_eWUV8i_l';
const REST = `https://${PROJECT}.supabase.co/rest/v1/rpc/jl_public_state`;
const WS = `wss://${PROJECT}.supabase.co/realtime/v1/websocket?apikey=${encodeURIComponent(API_KEY)}&vsn=1.0.0`;

const realtimeOpened = new Rate('mixed_realtime_opened');
const realtimeJoined = new Rate('mixed_realtime_joined');
const realtimeEarlyClose = new Rate('mixed_realtime_early_close');

export const options = {
  scenarios: {
    ws_wave_1: { executor: 'per-vu-iterations', exec: 'realtimeUser', vus: 100, iterations: 1, startTime: '0s', maxDuration: '2m' },
    ws_wave_2: { executor: 'per-vu-iterations', exec: 'realtimeUser', vus: 100, iterations: 1, startTime: '5s', maxDuration: '2m' },
    ws_wave_3: { executor: 'per-vu-iterations', exec: 'realtimeUser', vus: 100, iterations: 1, startTime: '10s', maxDuration: '2m' },
    fallback_users: {
      executor: 'ramping-vus',
      exec: 'fallbackUser',
      startTime: '15s',
      startVUs: 0,
      stages: [
        { duration: '15s', target: 200 },
        { duration: '15s', target: 500 },
        { duration: '15s', target: 700 },
        { duration: '30s', target: 700 },
        { duration: '10s', target: 0 },
      ],
      gracefulRampDown: '5s',
    },
  },
  thresholds: {
    mixed_realtime_opened: ['rate>0.99'],
    mixed_realtime_joined: ['rate>0.99'],
    mixed_realtime_early_close: ['rate<0.01'],
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000', 'p(99)<2000'],
  },
};

const restParams = {
  headers: {
    apikey: API_KEY,
    'Content-Type': 'application/json',
  },
  tags: { scenario_kind: 'fallback_poll' },
};

export function fallbackUser() {
  const res = http.post(REST, '{}', restParams);
  check(res, {
    'fallback backend HTTP 200': (r) => r.status === 200,
  });
  sleep(2.7 + Math.random() * 0.6);
}

function roomIdFor(vu) {
  const tail = String(vu).padStart(12, '0').slice(-12);
  return `11111111-1111-4111-8111-${tail}`;
}

export function realtimeUser() {
  const started = Date.now();
  let opened = false;
  let joined = false;
  let early = false;
  let intentional = false;
  const topic = `realtime:ludo:room:${roomIdFor(__VU)}`;

  const res = ws.connect(WS, {}, (socket) => {
    socket.on('open', () => {
      opened = true;
      socket.send(JSON.stringify({
        topic,
        event: 'phx_join',
        payload: {
          config: {
            broadcast: { self: false, ack: false },
            presence: { key: '' },
            postgres_changes: [],
            private: false
          }
        },
        ref: '1',
        join_ref: '1'
      }));
    });

    socket.on('message', (raw) => {
      try {
        const msg = JSON.parse(raw);
        if (msg?.event === 'phx_reply' && msg?.ref === '1' && msg?.payload?.status === 'ok') joined = true;
      } catch (_) {}
    });

    socket.on('close', () => {
      if (!intentional && Date.now() - started < 70000) early = true;
    });

    socket.setInterval(() => {
      if (!opened) return;
      socket.send(JSON.stringify({ topic: 'phoenix', event: 'heartbeat', payload: {}, ref: String(Date.now()) }));
    }, 25000);

    socket.setTimeout(() => {
      intentional = true;
      socket.close();
    }, 75000);
  });

  if (!opened || !res) early = true;
  realtimeOpened.add(opened);
  realtimeJoined.add(joined);
  realtimeEarlyClose.add(early);

  check(null, {
    'mixed realtime opened': () => opened,
    'mixed realtime joined': () => joined,
    'mixed realtime stayed alive': () => !early,
  });
}
