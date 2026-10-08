"""The collector framework against a local fake source: rate limits, retries, the cache, the
run budget, freshness, and fixture recording and replay. No network and no API keys."""
import io;
import json;
import os;
import re;
import tempfile;
import time;
import from datetime { timedelta }
import from pathlib { Path }
import from jaclang.data.storage.storage { Storage }
import from models.research { Stamped }
import from research.collector {
    BudgetExceeded,
    CacheEntry,
    RECORD_DIR_ENV,
    RawCache,
    RunBudget,
    SourceClient,
    SourceError,
    TokenBucket,
    bucket_for,
    parse_utc,
    run_budget,
    split_fresh,
    utc_now
}
import from research.sources { Dataset, SOURCES, Source }
import from tests.fakes.source_server { FakeSource }

glob PROJECT_ROOT: Path = Path(__file__).resolve().parent.parent;
glob FIXTURES: Path = PROJECT_ROOT / "tests" / "fixtures" / "collector";
glob URL_ENV: str = "TRADING_AGENT_TEST_SOURCE_URL";

glob TEST_SOURCE: Source = Source(
    name="test",
    base_url="https://api.example.com",
    base_url_env=URL_ENV,
    per_minute=60000,
    burst=100,
    run_budget=100
);
glob NEWS: Dataset = Dataset(name="test.items", source="test", max_age_hours=72, cache_ttl_hours=24);
glob FILINGS: Dataset = Dataset(name="test.filings", source="test", max_age_hours=72);
glob ITEMS_BODY: str = json.loads((FIXTURES / "test.items-example.json").read_text())["body"];

"""Start the fake with the committed fixtures and point the test source at it."""
def start_fake -> FakeSource {
    started = FakeSource();
    os.environ[URL_ENV] = started.start();
    started.load(FIXTURES);
    return started;
}

glob fake: FakeSource = start_fake();
glob FAKE_URL: str = os.environ[URL_ENV];

obj Item(Stamped) {
    has id: int;
}

def fresh_cache -> RawCache {
    return RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage);
}

def make_client(cache: RawCache | None = None) -> SourceClient {
    fake.reset();
    return SourceClient(
        source=TEST_SOURCE,
        headers={"User-Agent": "trading-agent tests"},
        cache=cache or fresh_cache(),
        bucket=TokenBucket(per_minute=60000, burst=100),
        backoff_s=0.0
    );
}

def get_items(client: SourceClient, budget: RunBudget, dataset: Dataset = NEWS) -> str {
    return client.get(
        dataset, "/v1/items", budget, params={"symbol": "AAPL"}, secrets={"token": "s3cret"}, symbol="AAPL"
    ).body;
}

def budget(calls: int = 100) -> RunBudget {
    return RunBudget(limits={"test": calls});
}

test "a fetch replays the recorded fixture through the base-URL override" {
    client = make_client();
    spent = budget();
    fetched = client.get(
        NEWS, "/v1/items", spent, params={"symbol": "AAPL"}, secrets={"token": "s3cret"}, symbol="AAPL"
    );
    assert fetched.body == ITEMS_BODY;
    assert not fetched.from_cache;
    assert fake.misses == [];
    assert spent.spent == {"test": 1};
    # The secret and headers reach the source, but the stamped URL is the public one.
    assert fake.requests[0].params == {"symbol": "AAPL", "token": "s3cret"};
    assert fake.requests[0].headers["User-Agent"] == "trading-agent tests";
    assert fetched.source_url == "https://api.example.com/v1/items?symbol=AAPL";
}

test "a second fetch is a cache hit with no request and no budget spent" {
    client = make_client();
    spent = budget();
    first = get_items(client, spent);
    again = client.get(NEWS, "/v1/items", spent, params={"symbol": "AAPL"}, secrets={"token": "other"}, symbol="AAPL");
    assert again.body == first;
    assert again.from_cache;
    assert len(fake.requests) == 1;
    assert spent.spent == {"test": 1};
}

test "an entry older than the dataset's cache lifetime is fetched again" {
    cache = fresh_cache();
    client = make_client(cache);
    spent = budget();
    fetched = client.get(NEWS, "/v1/items", spent, params={"symbol": "AAPL"}, symbol="AAPL");
    key = next(iter(cache._storage().list_files("raw", recursive=True)));
    stale = (utc_now() - timedelta(hours=25)).isoformat();
    cache.write(CacheEntry(key=key, source_url=fetched.source_url, fetched_at=stale, body="old"));
    refreshed = client.get(NEWS, "/v1/items", spent, params={"symbol": "AAPL"}, symbol="AAPL");
    assert not refreshed.from_cache;
    assert refreshed.body == ITEMS_BODY;
    assert len(fake.requests) == 2;
}

test "a dataset with no cache lifetime, such as filings, never expires" {
    cache = fresh_cache();
    client = make_client(cache);
    spent = budget();
    fetched = client.get(FILINGS, "/v1/items", spent, params={"symbol": "AAPL"}, symbol="AAPL", day="2026-01-02");
    key = next(iter(cache._storage().list_files("raw", recursive=True)));
    year_old = (utc_now() - timedelta(days=365)).isoformat();
    cache.write(CacheEntry(key=key, source_url=fetched.source_url, fetched_at=year_old, body="kept"));
    again = client.get(FILINGS, "/v1/items", spent, params={"symbol": "AAPL"}, symbol="AAPL", day="2026-01-02");
    assert again.from_cache;
    assert again.body == "kept";
    assert len(fake.requests) == 1;
}

test "the cache is keyed by source, dataset, symbol, and date" {
    cache = fresh_cache();
    client = make_client(cache);
    client.get(FILINGS, "/v1/items", budget(), params={"symbol": "AAPL"}, symbol="AAPL", day="2026-01-02");
    keys = list(cache._storage().list_files("raw", recursive=True));
    assert len(keys) == 1;
    assert re.fullmatch(r"raw/test/test\.filings/AAPL/2026-01-02/[0-9a-f]{20}\.json", keys[0]), keys;
}

test "an unreadable cache entry is a miss, not a crash" {
    cache = fresh_cache();
    client = make_client(cache);
    get_items(client, budget());
    key = next(iter(cache._storage().list_files("raw", recursive=True)));
    cache._storage().upload(io.BytesIO(b"{torn"), key);
    assert get_items(client, budget()) == ITEMS_BODY;
    assert len(fake.requests) == 2;
}

test "429s and 5xx responses are retried, and every attempt is spent from the budget" {
    client = make_client();
    fake.script = [(429, {}, "slow down"), (503, {}, "down")];
    spent = budget();
    assert get_items(client, spent) == ITEMS_BODY;
    assert len(fake.requests) == 3;
    assert spent.spent == {"test": 3};
}

test "a source that keeps failing raises after the last retry" {
    client = make_client();
    fake.script = [(500, {}, "boom")] * 4;
    spent = budget();
    with testraises(SourceError) as raised {
        get_items(client, spent);
    }
    caught = raised.value as SourceError;
    assert caught.status == 500;
    assert len(fake.requests) == 4;
    assert spent.spent == {"test": 4};
}

test "a client error such as 404 is not retried" {
    client = make_client();
    fake.script = [(404, {}, "unknown symbol")];
    with testraises(SourceError) as raised {
        get_items(client, budget());
    }
    caught = raised.value as SourceError;
    assert caught.status == 404;
    assert "unknown symbol" in str(caught);
    assert len(fake.requests) == 1;
}

test "a connection failure is retried and raised with status 0" {
    client = make_client();
    os.environ[URL_ENV] = "http://127.0.0.1:9";
    try {
        with testraises(SourceError) as raised {
            get_items(client, budget());
        }
    } finally {
        os.environ[URL_ENV] = FAKE_URL;
    }
    caught = raised.value as SourceError;
    assert caught.status == 0;
    assert caught.url == "https://api.example.com/v1/items?symbol=AAPL";
}

test "Retry-After sets the wait before the next attempt" {
    client = make_client();
    fake.script = [(429, {"Retry-After": "7"}, "")];
    waits: list[float] = [];
    real_sleep = time.sleep;
    def record_sleep(seconds: float) {
        waits.append(seconds);
    }
    time.sleep = record_sleep;
    try {
        get_items(client, budget());
    } finally {
        time.sleep = real_sleep;
    }
    assert waits == [7.0];
}

test "a spent budget stops the fetch before any request" {
    client = make_client();
    spent = budget(calls=1);
    get_items(client, spent);
    with testraises(BudgetExceeded) {
        client.get(NEWS, "/v1/items", spent, params={"symbol": "MSFT"});
    }
    assert len(fake.requests) == 1;
    # Running out of budget is a SourceError, so a collector reports both as data gaps.
    assert issubclass(BudgetExceeded, SourceError);
}

test "a run's budget covers every configured source" {
    assert run_budget().limits == {name: s.run_budget for (name, s) in SOURCES.items()};
}

test "a dataset of another source is refused" {
    client = make_client();
    with testraises(ValueError) {
        client.get(Dataset(name="x", source="fred", max_age_hours=1), "/v1/items", budget());
    }
}

test "the token bucket allows a burst, then paces to the rate" {
    bucket = TokenBucket(per_minute=600, burst=2);
    start = time.monotonic();
    bucket.acquire();
    bucket.acquire();
    assert time.monotonic() - start < 0.05;
    for _ in range(3) {
        bucket.acquire();
    }
    assert time.monotonic() - start >= 0.29;
}

test "sources on one provider limit share a bucket" {
    assert bucket_for(SOURCES["sec_data"]) is bucket_for(SOURCES["sec_archives"]);
    assert bucket_for(SOURCES["finnhub"]) is not bucket_for(SOURCES["fred"]);
}

test "stale data is excluded and named in the gaps" {
    client = make_client();
    fetched = client.get(NEWS, "/v1/items", budget(), params={"symbol": "AAPL"});
    items = [Item(id=i["id"], stamp=fetched.stamp(i["published"])) for i in json.loads(fetched.body)["items"]];
    items.append(Item(id=3, stamp=fetched.stamp("not a date")));
    as_of = parse_utc(items[0].stamp.published_at) + timedelta(hours=1);
    (fresh, gaps) = split_fresh(items, NEWS, now=as_of);
    assert [i.id for i in fresh] == [1];
    assert len(gaps) == 2;
    assert "2026-09-01T13:30:00+00:00" in gaps[0] and "72-hour limit" in gaps[0];
    assert "no valid publish time" in gaps[1];
    assert fresh[0].stamp.source == "test" and fresh[0].stamp.dataset == "test.items";
    assert fresh[0].stamp.fetched_at == fetched.fetched_at;
}

test "a recorded live response replays from a fresh fake, without its secrets" {
    record_dir = Path(tempfile.mkdtemp());
    client = make_client();
    fake.script = [(200, {}, ITEMS_BODY)];
    os.environ[RECORD_DIR_ENV] = str(record_dir);
    try {
        client.get(NEWS, "/v1/items", budget(), params={"symbol": "AAPL", "limit": 2}, secrets={"token": "s3cret"});
    } finally {
        del os.environ[RECORD_DIR_ENV];
    }
    files = list((record_dir / "test").glob("test.items-*.json"));
    assert len(files) == 1;
    assert "s3cret" not in files[0].read_text();

    replay = FakeSource();
    replay.load(record_dir / "test");
    os.environ[URL_ENV] = replay.start();
    try {
        again = make_client().get(NEWS, "/v1/items", budget(), params={"limit": 2, "symbol": "AAPL"}, secrets={"token": "other"});
    } finally {
        replay.stop();
        os.environ[URL_ENV] = FAKE_URL;
    }
    assert replay.misses == [];
    assert again.body == ITEMS_BODY;
}

test "collectors never touch the graph, since they run inside flow" {
    graph_ops = re.compile(r"\broot\b|\bhere\b|\bvisitor\b|\bspawn\b|\bgrant\(|\+\+>|<\+\+|\+>:|:\+>|\[\s*-->|\[edge\b");
    offenders: list[str] = [];
    for path in (PROJECT_ROOT / "research").rglob("*.jac") {
        if path.name.endswith("_tests.jac") or path.name.endswith(".test.jac") {
            continue;
        }
        code = re.sub(r'"""[\s\S]*?"""|#[^\n]*', "", path.read_text());
        if graph_ops.search(code) {
            offenders.append(path.name);
        }
    }
    assert not offenders, f"Collectors return values; write to the graph after wait: {offenders}";
}
