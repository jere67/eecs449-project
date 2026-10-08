"""A local stand-in for any data source, replaying recorded fixtures for collector tests.

Point a source's base-URL override (such as FINNHUB_BASE_URL) at `start()`'s URL, and the
server answers each GET from the recording with the same path and query. Recordings are
the files a live run writes under COLLECTOR_RECORD_DIR (research/collector.jac); trim
large bodies before committing them. Query parameters named in `secret_params` are ignored
when matching, since recordings never contain keys.

Scripted responses are served first, in order, to inject 429s and outages. Every request
is logged, and a request with no recording gets a 404 and is listed in `misses`.
"""
import json;
import threading;
import from http.server { BaseHTTPRequestHandler, ThreadingHTTPServer }
import from pathlib { Path }
import from urllib.parse { parse_qsl, urlsplit }
import from research.collector { request_key }

obj SeenRequest {
    has path: str,
        params: dict[str, str],
        headers: dict[str, str];
}

obj FakeSource {
    has recordings: dict[str, str] = {},
        script: list[tuple[int, dict[str, str], str]] = [],
        requests: list[SeenRequest] = [],
        misses: list[str] = [],
        secret_params: set[str] = {"token", "api_key"};
    has _server: ThreadingHTTPServer | None = None,
        _lock: threading.Lock | None = None;

    """Serve on a free local port and return the URL to use as a base-URL override."""
    def start -> str {
        self._lock = threading.Lock();
        server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler);
        setattr(server, "fake", self);
        self._server = server;
        threading.Thread(target=server.serve_forever, daemon=True).start();
        return f"http://127.0.0.1:{server.server_address[1]}";
    }

    def stop {
        if self._server {
            self._server.shutdown();
            self._server.server_close();
        }
    }

    """Add every recording in `directory` (*.json, as written by the recorder)."""
    def load(directory: Path) {
        for file in sorted(directory.glob("*.json")) {
            recorded = json.loads(file.read_text());
            self.recordings[request_key(recorded["path"], recorded["params"])] = recorded["body"];
        }
    }

    def reset {
        self.script = [];
        self.requests = [];
        self.misses = [];
    }

    """Log a request and return the (status, headers, body) to answer it with."""
    def answer(path: str, params: dict[str, str], headers: dict[str, str]) -> tuple[int, dict[str, str], str] {
        with self._lock {
            self.requests.append(SeenRequest(path=path, params=params, headers=headers));
            if self.script {
                return self.script.pop(0);
            }
        }
        public = {k: v for (k, v) in params.items() if k not in self.secret_params};
        key = request_key(path, public);
        if key in self.recordings {
            return (200, {}, self.recordings[key]);
        }
        with self._lock {
            self.misses.append(key);
        }
        return (404, {}, f"no recording for {key}");
    }
}

class _Handler(BaseHTTPRequestHandler) {
    def do_GET(self: _Handler) {
        url = urlsplit(self.path);
        fake = getattr(self.server, "fake") as FakeSource;
        (status, headers, body) = fake.answer(
            url.path, dict(parse_qsl(url.query)), dict(self.headers.items())
        );
        data = body.encode();
        self.send_response(status);
        for (name, value) in headers.items() {
            self.send_header(name, value);
        }
        self.send_header("Content-Length", str(len(data)));
        self.end_headers();
        self.wfile.write(data);
    }

    def log_message(self: _Handler, _fmt: str, *_args: object) {}
}
