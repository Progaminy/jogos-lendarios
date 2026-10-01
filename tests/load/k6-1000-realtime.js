import ws from 'k6/ws';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const PROJECT = __ENV.SUPABASE_PROJECT || 'bxndjyzghgrmkelshtdp';
const API_KEY = __ENV.SUPABASE_ANON_KEY || 'sb_publishable_E-Uikud2p7M6-dgcCK5ttg_eWUV8i_l';
const URL = `wss://${PROJECT}.supabase.co/realtime/v1/websocket?apikey=${encodeURIComponent(API_KEY)}&vsn=1.0.0`;

const openedRate = new Rate('realtime_opened');
const joinedRate = new Rate('realtime_joined');
const earlyCloseRate = new Rate('realtime_early_close');

const scenarios = {};
for (let i = 0; i < 10; i += 1) {
  scenarios[`wave_${i + 1}`] = {
    executor: 'per-vu-iterations',
    vus: 100,
    iterations: 1,
    startTime: `${i * 5}s`,
    maxDuration: '2m',
  };
}

export const options = {
  scenarios,
  thresholds: {
    realtime_opened: ['rate>0.99'],
    realtime_joined: ['rate>0.99'],
    realtime_early_close: ['rate<0.01'],
    ws_connecting: ['p(95)<3000'],
  },
};

function fakeRoomId(vu, scenario) {
  const n = Math.abs((vu * 97) + scenario.length);
  const tail = String(n).padStart(12, '0').slice(-12);
  return `00000000-0000-4000-8000-${tail}`;
}

export default function () {
  const startedAt = Date.now();
  let opened = false;
  let joined = false;
  let earlyClose = false;
  let intentionalClose = false;

  const roomId = fakeRoomId(__VU, __ENV.K6_SCENARIO || 'wave');
  const topic = `realtime:ludo:room:${roomId}`;

  const res = ws.connect(URL, {}, function (socket) {
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
        if (
          msg &&
          msg.event === 'phx_reply' &&
          msg.ref === '1' &&
          msg.payload &&
          msg.payload.status === 'ok'
        ) {
          joined = true;
        }
      } catch (_) {}
    });

    socket.on('close', () => {
      if (!intentionalClose && Date.now() - startedAt < 55000) {
        earlyClose = true;
      }
    });

    socket.setInterval(() => {
      if (!opened) return;
      socket.send(JSON.stringify({
        topic: 'phoenix',
        event: 'heartbeat',
        payload: {},
        ref: String(Date.now())
      }));
    }, 25000);

    socket.setTimeout(() => {
      intentionalClose = true;
      socket.close();
    }, 60000);
  });

  if (!opened || !res) earlyClose = true;

  openedRate.add(opened);
  joinedRate.add(joined);
  earlyCloseRate.add(earlyClose);

  check(null, {
    'realtime websocket opened': () => opened,
    'realtime channel joined': () => joined,
    'connection stayed alive': () => !earlyClose,
  });
}
