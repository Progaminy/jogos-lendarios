import http from 'k6/http';
import { check, sleep } from 'k6';

const SUPABASE_URL = __ENV.SUPABASE_URL || 'https://bxndjyzghgrmkelshtdp.supabase.co';
const API_KEY = __ENV.SUPABASE_ANON_KEY || 'sb_publishable_E-Uikud2p7M6-dgcCK5ttg_eWUV8i_l';

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
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000', 'p(99)<2000'],
    checks: ['rate>0.99'],
  },
};

const params = {
  headers: {
    apikey: API_KEY,
    'Content-Type': 'application/json',
  },
  tags: { endpoint: 'jl_public_state' },
};

export default function () {
  const res = http.post(
    SUPABASE_URL + '/rest/v1/rpc/jl_public_state',
    '{}',
    params
  );

  check(res, {
    'public state HTTP 200': (r) => r.status === 200,
    'public state returns JSON': (r) => {
      try {
        JSON.parse(r.body);
        return true;
      } catch (_) {
        return false;
      }
    },
  });

  // A página pública atualiza este estado a cada 20 segundos.
  // Pequeno jitter evita que 1000 clientes disparem exatamente no mesmo milissegundo.
  sleep(18 + Math.random() * 4);
}
