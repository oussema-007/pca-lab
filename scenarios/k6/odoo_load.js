// PCA lab - realistic Odoo sales user load through the load balancer.
// Each VU logs in once (vendeur1/vendeur2), then loops: list sales orders, list customers, list products, open the web client.
// Env: BASE VUS DURATION THINK SUMMARY PCA_HDR_NAME PCA_HDR_VALUE PCA_PW1 PCA_PW2
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate } from 'k6/metrics';

const BASE = __ENV.BASE || 'https://odoo.pca.lab';
const HDR = { 'Content-Type': 'application/json' };
HDR[__ENV.PCA_HDR_NAME] = __ENV.PCA_HDR_VALUE;          // rate-limit exemption (secret, stripped by HAProxy)
const THINK = parseFloat(__ENV.THINK || '0.5');
const rpcErrors = new Counter('rpc_errors');
const businessOk = new Rate('business_ok');

export const options = {
  scenarios: { load: { executor: 'constant-vus', vus: parseInt(__ENV.VUS || '5'), duration: __ENV.DURATION || '60s' } },
  noCookiesReset: true,   // keep session + SRV cookie across iterations, like a real browser (k6 resets the jar by default)
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: { http_req_failed: ['rate<0.01'] },
};

function rpc(model, method, args, kwargs) {
  const body = JSON.stringify({ jsonrpc: '2.0', method: 'call', params: { model, method, args, kwargs } });
  const r = http.post(`${BASE}/web/dataset/call_kw/${model}/${method}`, body, { headers: HDR, tags: { name: `${model}.${method}` } });
  let ok = r.status === 200;
  if (ok) { try { const j = r.json(); ok = j.result !== undefined && !j.error; } catch (e) { ok = false; } }
  if (!ok) rpcErrors.add(1);
  businessOk.add(ok);
  return r;
}

function login() {
  const user = __VU % 2 ? 'vendeur1' : 'vendeur2';
  const pw = user === 'vendeur1' ? __ENV.PCA_PW1 : __ENV.PCA_PW2;
  const r = http.post(`${BASE}/web/session/authenticate`,
    JSON.stringify({ jsonrpc: '2.0', params: { db: 'pca_demo', login: user, password: pw } }),
    { headers: HDR, tags: { name: 'authenticate' } });
  const ok = check(r, { 'login ok': (x) => x.status === 200 && !!x.json('result.uid') });
  businessOk.add(ok);
  if (!ok) rpcErrors.add(1);
}

export default function () {
  if (__ITER === 0) login();
  rpc('sale.order', 'search_read', [[]], { fields: ['name', 'partner_id', 'amount_total', 'state', 'date_order'], limit: 20, order: 'date_order desc' });
  rpc('res.partner', 'search_read', [[['is_company', '=', true]]], { fields: ['name', 'email', 'city', 'country_id'], limit: 20 });
  rpc('product.product', 'search_read', [[['sale_ok', '=', true]]], { fields: ['name', 'list_price', 'default_code'], limit: 20 });
  const p = http.get(`${BASE}/web`, { headers: { [__ENV.PCA_HDR_NAME]: __ENV.PCA_HDR_VALUE }, tags: { name: 'page /web' } });
  const ok = check(p, { 'web client 200': (x) => x.status === 200 });
  businessOk.add(ok);
  if (THINK > 0) sleep(THINK);
}

export function handleSummary(data) {
  const m = data.metrics, v = (k, f) => (m[k] && m[k].values[f] !== undefined ? m[k].values[f] : 0);
  const line = `k6: reqs=${v('http_reqs', 'count')} rps=${v('http_reqs', 'rate').toFixed(1)} p95=${v('http_req_duration', 'p(95)').toFixed(1)}ms ` +
    `failed=${v('http_req_failed', 'passes')} (${(100 * v('http_req_failed', 'rate')).toFixed(3)}%) rpc_errors=${v('rpc_errors', 'count')}\n`;
  const out = { stdout: line };
  if (__ENV.SUMMARY) out[__ENV.SUMMARY] = JSON.stringify(data, null, 1);
  return out;
}
