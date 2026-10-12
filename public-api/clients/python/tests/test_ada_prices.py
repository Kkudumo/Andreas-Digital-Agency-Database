import json, sys, tempfile, threading, unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ada_prices import Prices

SNAP = {'division': 'tech', 'services': [
    {'name': 'Windows Ready', 'billing_unit': 'job', 'price': {'amount': 649, 'currency': 'NAD', 'starting_price': False}},
    {'name': 'Remote quick support', 'billing_unit': 'job', 'price': {'amount': 149, 'currency': 'NAD', 'starting_price': True}},
    {'name': 'Web thing', 'billing_unit': 'job', 'price': {'amount': 2629.99, 'currency': 'NAD', 'starting_price': True}},
    {'name': 'CCTV installation', 'billing_unit': 'project'},
]}

def serve(payload, status=200):
    seen = {}
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            seen['path'] = self.path; seen['auth'] = self.headers.get('Authorization')
            self.send_response(status); self.send_header('content-type', 'application/json'); self.end_headers()
            self.wfile.write(json.dumps(payload).encode())
        def log_message(self, *a): pass
    srv = HTTPServer(('127.0.0.1', 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f'http://127.0.0.1:{srv.server_port}', seen

class T(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.snap = Path(self.d.name) / 'prices.json'; self.snap.write_text(json.dumps(SNAP)); self.logs = []
    def tearDown(self): self.d.cleanup()
    def P(self, **kw): return Prices('tech', self.snap, log=self.logs.append, **kw)

    def test_snapshot_only(self):
        p = self.P(api_url='', api_key='')
        self.assertEqual(p.source, 'snapshot')
        self.assertEqual((p.money('Windows Ready'), p.money('Web thing'), p.number('Web thing')), ('N$649', 'N$2,629.99', '2,629.99'))
        self.assertEqual((p.from_money('Remote quick support'), p.from_money('Windows Ready')), ('From N$149', 'N$649'))
        self.assertTrue(p.quoted('CCTV installation')); self.assertFalse(p.quoted('Windows Ready'))
        self.assertEqual(p.money(' windows   READY '), 'N$649')

    def test_unknown_or_quoted_stops_the_build(self):
        p = self.P(api_url='', api_key='')
        with self.assertRaises(KeyError): p.money('Windows Redy')
        with self.assertRaises(KeyError): p.money('CCTV installation')

    def test_api_overrides_changed_prices_and_flags_and_sends_the_key_as_bearer(self):
        srv, url, seen = serve([{'name': 'Windows Ready', 'billing_unit': 'job', 'price': {'amount': 699, 'currency': 'NAD', 'starting_price': True}}, {'name': 'Something else', 'price': {'amount': 1}}])
        try: p = self.P(api_url=url, api_key='ada_key_for_test')
        finally: srv.shutdown()
        self.assertEqual(p.source, 'api'); self.assertEqual(seen['path'], '/api/public/services?division=tech'); self.assertEqual(seen['auth'], 'Bearer ada_key_for_test')
        self.assertEqual(p.from_money('Windows Ready'), 'From N$699')           # price and the "from" flag both come from ADA Core
        self.assertEqual(p.money('Remote quick support'), 'N$149')              # not returned by the API: snapshot kept
        self.assertTrue(any('Windows Ready: 649 -> 699' in l for l in self.logs)); self.assertTrue(any('Remote quick support' in l for l in self.logs))
        self.assertFalse(any('ada_key_for_test' in l for l in self.logs))

    def test_unreachable_or_broken_api_falls_back_and_says_so(self):
        p = self.P(api_url='http://127.0.0.1:9', api_key='k', timeout=1)
        self.assertEqual((p.source, p.money('Windows Ready')), ('snapshot', 'N$649')); self.assertTrue(any('unavailable' in l for l in self.logs))
        srv, url, _ = serve({'error': 'x'})
        try: p = self.P(api_url=url, api_key='k')
        finally: srv.shutdown()
        self.assertEqual((p.source, p.money('Windows Ready')), ('snapshot', 'N$649'))
        srv, url, _ = serve([], status=403)
        try: p = self.P(api_url=url, api_key='k')
        finally: srv.shutdown()
        self.assertEqual(p.source, 'snapshot')

    def test_half_configured_api_is_ignored_loudly(self):
        p = self.P(api_url='https://x.example', api_key='')
        self.assertEqual(p.source, 'snapshot'); self.assertTrue(any('must both be set' in l for l in self.logs))

if __name__ == '__main__': unittest.main()
