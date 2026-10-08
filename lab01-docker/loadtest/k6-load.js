// k6 run loadtest/k6-load.js            (mặc định 50 VU trong 60s qua nginx :8080)
// BASE_URL=http://localhost:8080 VUS=50 DURATION=60s k6 run loadtest/k6-load.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  scenarios: {
    shop: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '15s', target: Number(__ENV.VUS || 50) },
        { duration: __ENV.DURATION || '60s', target: Number(__ENV.VUS || 50) },
        { duration: '10s', target: 0 },
      ],
    },
  },
  // TARGET của lab: p95 < 200ms, lỗi < 1%
  thresholds: {
    http_req_duration: ['p(95)<200'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const r1 = http.get(`${BASE}/orders`);
  check(r1, { 'list 200': (r) => r.status === 200 });

  if (Math.random() < 0.3) {
    const payload = JSON.stringify({ customer: `vu-${__VU}`, item: 'book', quantity: 1 + (__ITER % 3), price: 12.5 });
    const r2 = http.post(`${BASE}/orders`, payload, { headers: { 'Content-Type': 'application/json' } });
    check(r2, { 'create 201': (r) => r.status === 201 });
  }
  sleep(0.5 + Math.random());   // ~1,3 req/s mỗi VU → 50 VU ≈ 65 req/s, dưới rate limit 100r/s của nginx
}
