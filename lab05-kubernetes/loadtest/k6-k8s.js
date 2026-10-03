// Tải liên tục trong lúc rollout / HPA.
//   BASE_URL=http://shop.127.0.0.1.nip.io VUS=30 DURATION=3m k6 run loadtest/k6-k8s.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://shop.127.0.0.1.nip.io';
export const options = {
  vus: Number(__ENV.VUS || 30),
  duration: __ENV.DURATION || '3m',
  thresholds: {
    http_req_failed: ['rate<0.01'],          // TARGET: < 1% lỗi kể cả khi đang rollout
    http_req_duration: ['p(95)<500'],
  },
};

export default function () {
  const r = http.get(`${BASE}/orders`);
  check(r, { '200': (x) => x.status === 200 });
  if (__ITER % 5 === 0) {
    http.post(`${BASE}/orders`, JSON.stringify({ customer: `k6-${__VU}`, item: 'k8s', quantity: 1, price: 3 }),
      { headers: { 'Content-Type': 'application/json' } });
  }
  sleep(Number(__ENV.SLEEP || 0.2));
}
