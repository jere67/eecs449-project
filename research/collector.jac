"""Shared machinery for every collector (TDD §6, collector rules).

A collector fetches through `SourceClient.get`, which:

1. answers from the raw cache in store() while the entry is younger than the dataset's
   cache lifetime, with no request and no budget spent;
2. otherwise spends one call of the run's budget and waits for the source's token bucket;
3. retries timeouts, connection errors, 429s, and 5xx responses with exponential backoff,
   honoring Retry-After, and spends budget and a token on every attempt;
4. checks the body when the collector passes `check`, so an error page sent with status 200
   is never cached;
5. caches the raw body with its fetch time and returns it.

The collector parses the body into Stamped values with `Fetched.stamp`, and drops stale
ones with `split_fresh`, which names each dropped datum for the report's data_gaps.

Collectors return values and never read or write the graph: they run inside `flow`, whose
worker threads lose the request's graph context (TDD §3, rules 5 and 6).
"""
import hashlib;
import io;
import json;
import os;
import threading;
import time;
import from datetime { datetime, timedelta, timezone }
import from email.utils { parsedate_to_datetime }
import from pathlib { Path }
import from urllib.parse { urlencode }
import httpx;
import from jaclang.data.storage.storage { Storage }
import from models.research { Stamp, Stamped }
import from research.sources { Dataset, SOURCES, Source }

"""Set to a directory to save every live response as a replayable fixture."""
glob RECORD_DIR_ENV: str = "COLLECTOR_RECORD_DIR";
glob MAX_RETRY_AFTER_S: float = 60.0;

def utc_now -> datetime {
    return datetime.now(timezone.utc);
}

"""Parse an ISO 8601 date or timestamp; one without a zone is taken as UTC."""
def parse_utc(text: str) -> datetime {
    when = datetime.fromisoformat(text);
    if when.tzinfo is None {
        return when.replace(tzinfo=timezone.utc);
    }
    return when.astimezone(timezone.utc);
}

"""A request's identity: its path and sorted query, without secrets."""
def request_key(path: str, params: dict[str, str]) -> str {
    return f"{path}?{urlencode(sorted(params.items()))}";
}

def _digest(text: str) -> str {
    return hashlib.sha256(text.encode()).hexdigest()[:20];
}

"""A source refused a request or kept failing. Status 0 means no HTTP response."""
obj SourceError(Exception) {
    has source: str,
        url: str,
        status: int = 0,
        detail: str = "";

    override def __str__ -> str {
        return f"{self.source}: {self.detail or 'request failed'} (status {self.status}, {self.url})";
    }
}

"""The run has spent its calls for a source; the collector reports the gap."""
obj BudgetExceeded(SourceError) {}

"""A source answered, but not with what the collector expects, such as an error page sent
with status 200 or a page whose layout changed."""
obj UnexpectedResponse(SourceError) {}

"""Allows `burst` requests at once, then `per_minute` evenly, across every thread."""
obj TokenBucket {
    has per_minute: float,
        burst: int;
    has _lock: threading.Lock | None = None,
        _tokens: float = 0.0,
        _updated: float = 0.0;

    def postinit {
        self._lock = threading.Lock();
        self._tokens = float(self.burst);
        self._updated = time.monotonic();
    }

    def _refill {
        now = time.monotonic();
        self._tokens = min(
            float(self.burst), self._tokens + (now - self._updated) * self.per_minute / 60.0
        );
        self._updated = now;
    }

    """Block until a token is free, then take it."""
    def acquire {
        with self._lock {
            self._refill();
            if self._tokens < 1.0 {
                time.sleep((1.0 - self._tokens) * 60.0 / self.per_minute);
                # Refill from the real wake-up time, which can be late.
                self._refill();
            }
            self._tokens -= 1.0;
        }
    }
}

glob _BUCKETS: dict[str, TokenBucket] = {};
glob _BUCKETS_LOCK: threading.Lock = threading.Lock();

"""The process-wide bucket for a source's limit group, so every client of it shares one."""
def bucket_for(source: Source) -> TokenBucket {
    with _BUCKETS_LOCK {
        if source.limit_group not in _BUCKETS {
            _BUCKETS[source.limit_group] = TokenBucket(
                per_minute=source.per_minute, burst=source.burst
            );
        }
        return _BUCKETS[source.limit_group];
    }
}

"""Calls a run may still make to each source. Cache hits are free."""
obj RunBudget {
    has limits: dict[str, int];
    has spent: dict[str, int] = {};
    has _lock: threading.Lock | None = None;

    def postinit {
        self._lock = threading.Lock();
    }

    def spend(source: str, url: str) {
        with self._lock {
            used = self.spent.get(source, 0);
            limit = self.limits.get(source, 0);
            if used >= limit {
                raise BudgetExceeded(
                    source=source, url=url, detail=f"run budget of {limit} calls is spent"
                );
            }
            self.spent[source] = used + 1;
        }
    }
}

"""A fresh budget for one run, from each source's configured run budget."""
def run_budget -> RunBudget {
    return RunBudget(limits={name: s.run_budget for (name, s) in SOURCES.items()});
}

obj CacheEntry {
    has key: str,
        source_url: str,
        fetched_at: str,
        body: str;
}

"""Raw responses in store(), keyed by source, dataset, symbol, and date (TDD §11)."""
obj RawCache {
    has storage: Storage | None = None;

    def _storage -> Storage {
        if self.storage is None {
            self.storage = store() as Storage;
        }
        return self.storage;
    }

    """The entry at `key`, or None when it is missing, unreadable, or older than `ttl_hours`."""
    def read(key: str, ttl_hours: float | None, now: datetime) -> CacheEntry | None {
        storage = self._storage();
        if not storage.exists(key) {
            return None;
        }
        try {
            hit = CacheEntry(**json.loads(storage.download(key) or b""));
            fetched = parse_utc(hit.fetched_at);
        } except (ValueError, TypeError) {
            # A torn or foreign file is a miss; the fetch overwrites it.
            return None;
        }
        if ttl_hours is not None and now - fetched > timedelta(hours=ttl_hours) {
            return None;
        }
        return hit;
    }

    def write(item: CacheEntry) {
        data = json.dumps(
            {
                "key": item.key,
                "source_url": item.source_url,
                "fetched_at": item.fetched_at,
                "body": item.body
            }
        );
        self._storage().upload(io.BytesIO(data.encode()), item.key);
    }
}

glob RAW_CACHE: RawCache = RawCache();

# One connection pool for every client; httpx.Client is safe to share across threads.
glob _HTTP: httpx.Client = httpx.Client(follow_redirects=True);

"""A raw response body and where and when it came from."""
obj Fetched {
    has source: str,
        dataset: str,
        source_url: str,
        fetched_at: str,
        body: str,
        from_cache: bool;

    """Provenance for one datum in this response. Pass `source_url` when the datum has its
    own page, such as a news article."""
    def stamp(published_at: str, source_url: str = "") -> Stamp {
        return Stamp(
            source=self.source,
            dataset=self.dataset,
            source_url=source_url or self.source_url,
            published_at=published_at,
            fetched_at=self.fetched_at
        );
    }
}

"""Fetches from one source with caching, its rate limit, retries, and the run budget.

`secrets` are query parameters added to every request, such as an API key; they are kept
out of cache keys, stamped URLs, and recorded fixtures. Header credentials go in `headers`,
which none of those keep.
"""
obj SourceClient {
    has source: Source;
    has headers: dict[str, str] = {},
        secrets: dict[str, str] = {},
        cache: RawCache = RAW_CACHE,
        bucket: TokenBucket | None = None,
        max_retries: int = 3,
        backoff_s: float = 1.0,
        timeout_s: float = 30.0;

    """The base URL requests go to: the override from the environment, if set."""
    def base_url -> str {
        return (os.environ.get(self.source.base_url_env) or self.source.base_url).rstrip("/");
    }

    """GET `path` under the source's base URL, from the cache when it is fresh enough.

    `symbol` and `day` place the response in the cache: pass the ticker or series, and the
    as-of date that makes the response final (a bar range's end date), so a response that
    can no longer change is never fetched twice. `day` defaults to today in UTC.
    `check` returns what is wrong with a fresh body, or "" when it is usable; a body it
    rejects is neither cached nor recorded, and raises UnexpectedResponse.
    Raises SourceError, or BudgetExceeded, which the collector reports as a data gap.
    """
    def get(
        dataset: Dataset,
        path: str,
        budget: RunBudget,
        params: dict[str, str | int | float] | None = None,
        symbol: str = "",
        day: str = "",
        check: Callable[[str], str] | None = None
    ) -> Fetched {
        if dataset.source != self.source.name {
            raise ValueError(f"dataset {dataset.name} belongs to {dataset.source}, not {self.source.name}");
        }
        query = {k: str(v) for (k, v) in (params or {}).items()};
        now = utc_now();
        request_id = request_key(path, query);
        key = "/".join(
            [
                "raw",
                self.source.name,
                dataset.name,
                symbol or "_",
                day or now.date().isoformat(),
                f"{_digest(request_id)}.json"
            ]
        );
        public_url = self.source.base_url.rstrip("/") + path;
        if query {
            public_url += "?" + urlencode(query);
        }

        cached = self.cache.read(key, dataset.cache_ttl_hours, now);
        if cached is not None {
            return Fetched(
                source=self.source.name,
                dataset=dataset.name,
                source_url=cached.source_url,
                fetched_at=cached.fetched_at,
                body=cached.body,
                from_cache=True
            );
        }

        body = self._fetch(path, {**query, **self.secrets}, public_url, budget);
        problem = check(body) if check else "";
        if problem {
            raise UnexpectedResponse(source=self.source.name, url=public_url, status=200, detail=problem);
        }
        fetched = Fetched(
            source=self.source.name,
            dataset=dataset.name,
            source_url=public_url,
            fetched_at=utc_now().isoformat(),
            body=body,
            from_cache=False
        );
        self.cache.write(
            CacheEntry(key=key, source_url=public_url, fetched_at=fetched.fetched_at, body=body)
        );
        _record(self.source.name, dataset.name, path, query, request_id, body);
        return fetched;
    }

    """The response body, after up to `max_retries` retries of transient failures."""
    def _fetch(path: str, params: dict[str, str], public_url: str, budget: RunBudget) -> str {
        bucket = self.bucket or bucket_for(self.source);
        failure = SourceError(source=self.source.name, url=public_url);
        for attempt in range(self.max_retries + 1) {
            budget.spend(self.source.name, public_url);
            bucket.acquire();
            wait_s = self.backoff_s * (2 ** attempt);
            try {
                response = _HTTP.get(
                    self.base_url() + path,
                    params=params,
                    headers=self.headers,
                    timeout=self.timeout_s
                );
            } except httpx.TransportError as e {
                failure = SourceError(
                    source=self.source.name, url=public_url, detail=type(e).__name__
                );
            } else {
                status = response.status_code;
                if 200 <= status < 300 {
                    return response.text;
                }
                failure = SourceError(
                    source=self.source.name,
                    url=public_url,
                    status=status,
                    detail=response.text[:200]
                );
                if status != 429 and status < 500 {
                    raise failure;
                }
                wait_s = _retry_after(response) or wait_s;
            }
            if attempt < self.max_retries {
                time.sleep(wait_s);
            }
        }
        raise failure;
    }
}

"""Seconds a 429 or 503 asks us to wait, capped at MAX_RETRY_AFTER_S, or None."""
def _retry_after(response: httpx.Response) -> float | None {
    value = response.headers.get("Retry-After", "").strip();
    if not value {
        return None;
    }
    try {
        seconds = float(value);
    } except ValueError {
        try {
            retry_at: datetime | None = parsedate_to_datetime(value);
            if retry_at is None {
                return None;
            }
            seconds = (retry_at - utc_now()).total_seconds();
        } except (TypeError, ValueError) {
            return None;
        }
    }
    return max(0.0, min(seconds, MAX_RETRY_AFTER_S));
}

"""Save a live response as a fixture that tests/fakes/source_server.jac can replay."""
def _record(
    source: str,
    dataset: str,
    path: str,
    params: dict[str, str],
    request_id: str,
    body: str
) {
    record_dir = os.environ.get(RECORD_DIR_ENV);
    if not record_dir {
        return;
    }
    target = Path(record_dir) / source / f"{dataset}-{_digest(request_id)}.json";
    target.parent.mkdir(parents=True, exist_ok=True);
    target.write_text(
        json.dumps({"path": path, "params": params, "status": 200, "body": body}, indent=1)
    );
}

"""Keep the items young enough for `dataset`, and describe each dropped one for data_gaps.

Freshness is measured from each datum's publish time, not its fetch time (GAP-15).
"""
def split_fresh[T: Stamped](items: list[T], dataset: Dataset, now: datetime | None = None) -> tuple[list[T], list[str]] {
    as_of = now or utc_now();
    limit = timedelta(hours=dataset.max_age_hours);
    fresh: list[T] = [];
    gaps: list[str] = [];
    for item in items {
        stamp = item.stamp;
        try {
            published = parse_utc(stamp.published_at);
        } except ValueError {
            gaps.append(
                f"{dataset.name}: {stamp.source_url} has no valid publish time ({stamp.published_at!r}), so it was excluded"
            );
            continue;
        }
        if as_of - published > limit {
            gaps.append(
                f"{dataset.name}: {stamp.source_url} was published {stamp.published_at}, older than the {dataset.max_age_hours:g}-hour limit, so it was excluded"
            );
        } else {
            fresh.append(item);
        }
    }
    return (fresh, gaps);
}
