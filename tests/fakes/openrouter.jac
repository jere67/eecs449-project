"""A local stand-in for OpenRouter's chat completions endpoint, for model-layer tests.

Requests are answered from a script of (status, content) pairs in order and recorded, so a
test can count exactly how many requests reached the provider. A request beyond the script
gets a 500, which makes an unexpected extra request fail loudly.
"""
import json;
import threading;
import from http.server { BaseHTTPRequestHandler, ThreadingHTTPServer }

obj FakeOpenRouter {
    has script: list[tuple[int, str]] = [],
        requests: list[dict] = [];
    has _server: ThreadingHTTPServer | None = None,
        _lock: threading.Lock | None = None;

    """Serve on a free local port and return the base URL to give a model."""
    def start -> str {
        self._lock = threading.Lock();
        server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler);
        setattr(server, "fake", self);
        self._server = server;
        threading.Thread(target=server.serve_forever, daemon=True).start();
        return f"http://127.0.0.1:{server.server_address[1]}/api/v1";
    }

    def stop {
        if self._server {
            self._server.shutdown();
            self._server.server_close();
        }
    }

    """Record a request and return the scripted (status, content) for it."""
    def answer(body: dict[str, object]) -> tuple[int, str] {
        with self._lock {
            index = len(self.requests);
            self.requests.append(body);
        }
        if index < len(self.script) {
            return self.script[index];
        }
        return (500, "");
    }
}

def completion_body(model: str, content: str) -> dict[str, object] {
    return {
        "id": "gen-fake",
        "object": "chat.completion",
        "created": 0,
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop"
            }
        ],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
    };
}

class _Handler(BaseHTTPRequestHandler) {
    def do_POST(self: _Handler) {
        length = int(self.headers.get("Content-Length", "0"));
        body = json.loads(self.rfile.read(length));
        fake = getattr(self.server, "fake") as FakeOpenRouter;
        (status, content) = fake.answer(body);
        if status == 200 {
            payload = completion_body(body.get("model", ""), content);
        } else {
            payload = {"error": {"message": f"fake status {status}", "code": status}};
        }
        data = json.dumps(payload).encode();
        self.send_response(status);
        self.send_header("Content-Type", "application/json");
        self.send_header("Content-Length", str(len(data)));
        self.end_headers();
        self.wfile.write(data);
    }

    def log_message(self: _Handler, _fmt: str, *_args: object) {}
}
