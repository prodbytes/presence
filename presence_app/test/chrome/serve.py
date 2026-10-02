"""Serves presence_app/ on 127.0.0.1:8766 with CORS, for
recognition_models_test.dart (models, web/tfjs/, fixtures).

    python3 test/chrome/serve.py &
    flutter test --platform chrome test/chrome/
"""
import http.server
import os

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        super().end_headers()

    def log_message(self, *args):
        pass

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
http.server.ThreadingHTTPServer(('127.0.0.1', 8766), Handler).serve_forever()
