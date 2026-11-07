#!/usr/bin/env python3
"""User-like probe: logs in once through the LB, then sends one authenticated JSON-RPC call every INTERVAL s.
Logs per request: epoch_ms, http status, latency, backend server (X-PCA-Server), SRV cookie, ok, error.
Usage: python3 -I probe.py --duration 90 --out file.csv [--pin odoo1] [--interval 0.2]"""
import argparse, json, os, ssl, sys, time, http.client, http.cookies, urllib.parse

ap = argparse.ArgumentParser()
ap.add_argument('--duration', type=float, default=60)
ap.add_argument('--interval', type=float, default=0.2)
ap.add_argument('--out', required=True)
ap.add_argument('--pin', default=None, help='initial SRV cookie (e.g. odoo1) so the probe starts on that node')
ap.add_argument('--login', default='vendeur2')
ap.add_argument('--close', action='store_true', help='send Connection: close on every request (default: keep-alive like a browser)')
a = ap.parse_args()
BASE = os.environ.get('BASE', 'https://odoo.pca.lab')
HDR = {os.environ['PCA_HDR_NAME']: os.environ['PCA_HDR_VALUE'], 'Content-Type': 'application/json'}
PW = os.environ['PCA_PW2'] if a.login == 'vendeur2' else os.environ['PCA_PW1']
ctx = ssl.create_default_context()
cookies = {}
if a.pin:
    cookies['SRV'] = a.pin

U = urllib.parse.urlsplit(BASE)
conn = None

def post(path, payload, timeout=15):
    """One HTTP/1.1 request on a persistent TLS connection (browser-like). A failed request is NOT retried here:
    the error is reported, and the next request opens a new connection."""
    global conn
    h = dict(HDR)
    if a.close:
        h['Connection'] = 'close'
    if cookies:
        h['Cookie'] = '; '.join(f'{k}={v}' for k, v in cookies.items())
    t0 = time.time()
    try:
        if conn is None:
            conn = http.client.HTTPSConnection(U.hostname, U.port or 443, timeout=timeout, context=ctx)
        conn.request('POST', path, body=json.dumps(payload).encode(), headers=h)
        r = conn.getresponse()
        status, body, hdrs = r.status, r.read(), r.headers
        if a.close or r.will_close:
            conn.close(); conn = None
    except Exception:
        if conn is not None:
            conn.close()
        conn = None
        raise
    lat = (time.time() - t0) * 1000
    for sc in hdrs.get_all('Set-Cookie') or []:
        c = http.cookies.SimpleCookie(); c.load(sc)
        for k, m in c.items():
            cookies[k] = m.value
    return status, body, hdrs.get('X-PCA-Server', ''), lat

st, body, srv, lat = post('/web/session/authenticate', {'jsonrpc': '2.0', 'params': {'db': 'pca_demo', 'login': a.login, 'password': PW}})
uid = json.loads(body).get('result', {}).get('uid')
if not uid:
    print('PROBE LOGIN FAILED', st, file=sys.stderr); sys.exit(2)
print(f'probe: logged in as {a.login} uid={uid} on {srv}', file=sys.stderr)
rows, end, nxt = [], time.time() + a.duration, time.time()
payload = {'jsonrpc': '2.0', 'method': 'call', 'params': {'model': 'sale.order', 'method': 'search_count', 'args': [[]], 'kwargs': {}}}
with open(a.out, 'w') as f:
    f.write('epoch_ms,status,latency_ms,server,srv_cookie,ok,error\n')
    while time.time() < end:
        ts = int(time.time() * 1000)
        err = ''
        try:
            st, body, srv, lat = post('/web/dataset/call_kw/sale.order/search_count', payload)
            j = json.loads(body) if st == 200 else {}
            ok = st == 200 and isinstance(j.get('result'), int)
            if not ok:
                err = (j.get('error', {}).get('data', {}).get('name') or f'http_{st}')[:60]
        except Exception as e:  # network error = user-visible failure
            st, srv, lat, ok, err = 0, '', 0, False, type(e).__name__
        f.write(f'{ts},{st},{lat:.1f},{srv},{cookies.get("SRV","")},{int(ok)},{err}\n'); f.flush()
        nxt += a.interval
        time.sleep(max(0, nxt - time.time()))
