import ws from 'k6/ws';
import { check } from 'k6';

const PROJECT = __ENV.SUPABASE_PROJECT || 'bxndjyzghgrmkelshtdp';
const API_KEY = __ENV.SUPABASE_ANON_KEY || 'sb_publishable_E-Uikud2p7M6-dgcCK5ttg_eWUV8i_l';
const URL = `wss://${PROJECT}.supabase.co/realtime/v1/websocket?apikey=${encodeURIComponent(API_KEY)}&vsn=1.0.0`;

export const options = {
  stages: [
    { duration: '20s', target: 100 },
    { duration: '20s', target: 300 },
    { duration: '20s', target: 600 },
    { duration: '20s', target: 1000 },
    { duration: '60s', target: 1000 },
    { duration: '20s', target: 0 },
  ],
  thresholds: {
    checks: ['rate>0.99'],
    ws_connecting: ['p(95)<2000'],
  },
};

function fakeRoomId(vu) {
  const tail = String(vu).padStart(12, '0').slice(-12);
  return `00000000-0000-4000-8000-${tail}`;
}

export default function () {
  let opened = false;
  let joined = false;
  const roomId = fakeRoomId(__VU);
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

    socket.setInterval(() => {
      if (opened) {
        socket.send(JSON.stringify({
          topic: 'phoenix',
          event: 'heartbeat',
          payload: {},
          ref: String(Date.now())
        }));
      }
    }, 25000);

    socket.setTimeout(() => {
      check(null, {
        'realtime websocket opened': () => opened,
        'realtime channel joined': () => joined,
      });
      socket.close();
    }, 90000);
  });

  check(res, {
    'websocket handshake HTTP 101': (r) => r && r.status === 101,
  });
}
