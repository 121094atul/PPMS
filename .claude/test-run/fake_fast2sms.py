"""Nakli Fast2SMS (sirf local test): /dev/bulkV2 par aaye har request ko log karta hai.
Key 'bad-key' ho to Fast2SMS jaisa galti ka jawab (400, return:false)."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

LOG = sys.argv[1]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        form = {k: v[0] for k, v in parse_qs(body).items()}
        key = self.headers.get('authorization')
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(json.dumps({'path': self.path, 'auth': key, 'form': form}) + '\n')
        if key == 'bad-key':
            code, out = 400, {'return': False, 'status_code': 412, 'message': 'Invalid Authentication, Check Authorization Key'}
        else:
            code, out = 200, {'return': True, 'request_id': 'test123', 'message': ['SMS sent successfully.']}
        data = json.dumps(out).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass

HTTPServer(('127.0.0.1', 5299), H).serve_forever()
