#!/usr/bin/env python3
"""Simple HTTP server that prints request headers and decodes any Bearer JWT."""
from http.server import HTTPServer, BaseHTTPRequestHandler
import base64, json, sys

class Handler(BaseHTTPRequestHandler):
    def handle_request(self):
        print(f'\n── {self.command} {self.path} ──', flush=True)
        print('Headers:', flush=True)
        for k, v in self.headers.items():
            print(f'  {k}: {v}', flush=True)

        auth = self.headers.get('Authorization', '')
        if auth.startswith('Bearer '):
            parts = auth[7:].split('.')
            if len(parts) >= 2:
                padded = parts[1] + '=' * (-len(parts[1]) % 4)
                try:
                    claims = json.loads(base64.b64decode(padded))
                    print('\nJWT claims:', flush=True)
                    print(json.dumps(claims, indent=2), flush=True)
                except Exception as e:
                    print(f'Could not decode JWT: {e}', flush=True)

        length = int(self.headers.get('Content-Length', 0))
        if length:
            body = self.rfile.read(length)
            print(f'\nBody: {body.decode()[:500]}', flush=True)

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{}')

    do_GET = do_POST = do_PUT = handle_request

    def log_message(self, *args):
        pass  # suppress default access log

port = int(sys.argv[1]) if len(sys.argv) > 1 else 9999
print(f'Listening on http://localhost:{port}', flush=True)
HTTPServer(('', port), Handler).serve_forever()