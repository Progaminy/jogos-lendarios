import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'https://jogoslendarios.adadpsf.shop';

export const options = {
  stages: [
    { duration: '20s', target: 100 },
    { duration: '20s', target: 300 },
    { duration: '20s', target: 600 },
    { duration: '20s', target: 1000 },
    { duration: '30s', target: 1000 },
    { duration: '20s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<2000', 'p(99)<4000'],
    checks: ['rate>0.99'],
  },
  discardResponseBodies: true,
};

export default function () {
  const responses = http.batch([
    ['GET', BASE + '/', null, { tags: { page: 'home' } }],
    ['GET', BASE + '/ludo.html', null, { tags: { page: 'ludo' } }],
    ['GET', BASE + '/manifest.webmanifest', null, { tags: { page: 'manifest' } }],
  ]);

  check(responses[0], { 'home 2xx/3xx': (r) => r.status >= 200 && r.status < 400 });
  check(responses[1], { 'ludo 2xx/3xx': (r) => r.status >= 200 && r.status < 400 });
  check(responses[2], { 'manifest 2xx/3xx': (r) => r.status >= 200 && r.status < 400 });

  // 1000 utilizadores simultâneos, mas com comportamento humano:
  // cada utilizador não dispara pedidos continuamente.
  sleep(8 + Math.random() * 4);
}
