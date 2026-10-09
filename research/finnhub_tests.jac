"""The Finnhub collector against recorded responses. No network and no real key."""
import json;
import os;
import tempfile;
import from pathlib { Path }
import from jaclang.data.storage.storage { Storage }
import from research.collector { MissingKey, RawCache, RunBudget, SourceClient, SourceError, TokenBucket }
import from research.finnhub {
    CALENDAR_ROW_CAP,
    KEY_METRICS,
    company_news,
    earnings_calendar,
    eps_surprises,
    finnhub_client,
    key_metrics,
    recommendation_trends
}
import from research.sources { SOURCES }
import from tests.fakes.source_server { FakeSource, serve_source }

glob FIXTURES: Path = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "finnhub";
glob fake: FakeSource = serve_source(SOURCES["finnhub"].base_url_env, FIXTURES);

def client -> SourceClient {
    fake.reset();
    return SourceClient(
        source=SOURCES["finnhub"],
        headers={"X-Finnhub-Token": "test-token"},
        cache=RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage),
        bucket=TokenBucket(per_minute=60000, burst=100),
        backoff_s=0.0
    );
}

def budget -> RunBudget {
    return RunBudget(limits={"finnhub": 50});
}

def calendar_rows(day: str, count: int) -> str {
    return json.dumps({"earningsCalendar": [{"symbol": f"S{i}", "date": day} for i in range(count)]});
}

test "company news is newest first, cites each article, and sends the key as a header" {
    found = company_news("AAPL", "2026-10-08", "2026-10-08", budget(), client(), limit=5);
    assert fake.misses == [];
    assert len(found) == 5;
    assert found[0].created_at == "2026-10-08T23:03:06+00:00";
    assert [a.created_at for a in found] == sorted([a.created_at for a in found], reverse=True);
    assert found[0].stamp.source_url == found[0].url and found[0].url.startswith("https://finnhub.io/api/news?id=");
    assert found[0].content == "" and found[0].summary;
    assert fake.requests[0].headers["X-Finnhub-Token"] == "test-token";
    assert "token" not in fake.requests[0].params;
}

test "the earnings calendar lists every company's releases" {
    (releases, gaps) = earnings_calendar("2026-10-08", "2026-10-09", budget(), client());
    assert fake.misses == [] and gaps == [];
    assert len(releases) == 22;
    delta = [r for r in releases if r.symbol == "DAL"][0];
    assert (delta.day, delta.hour, delta.eps_estimate, delta.eps_actual) == ("2026-10-09", "bmo", 1.9868, None);
}

test "a calendar range that fills the row cap is split until it does not" {
    data = client();
    fake.script = [
        (200, {}, calendar_rows("2026-10-04", CALENDAR_ROW_CAP)),
        (200, {}, calendar_rows("2026-10-01", 3)),
        (200, {}, calendar_rows("2026-10-03", 2))
    ];
    (releases, gaps) = earnings_calendar("2026-10-01", "2026-10-04", budget(), data);
    assert gaps == [];
    assert [(r["from"], r["to"]) for r in [q.params for q in fake.requests]] == [
        ("2026-10-01", "2026-10-04"), ("2026-10-01", "2026-10-02"), ("2026-10-03", "2026-10-04")
    ];
    assert len(releases) == 5;
}

test "a single day at the row cap is named as a gap, and repeated rows are dropped" {
    data = client();
    rows = json.loads(calendar_rows("2026-10-01", CALENDAR_ROW_CAP));
    rows["earningsCalendar"][1]["symbol"] = "S0";
    fake.script = [(200, {}, json.dumps(rows))];
    (releases, gaps) = earnings_calendar("2026-10-01", "2026-10-01", budget(), data);
    assert len(releases) == CALENDAR_ROW_CAP - 1;
    assert len(gaps) == 1 and "some may be missing" in gaps[0];
}

test "recommendation trends and EPS surprises are dated by their period" {
    data = client();
    trends = recommendation_trends("AAPL", budget(), data);
    assert [t.period for t in trends] == ["2026-09-01", "2026-08-01", "2026-07-01", "2026-06-01"];
    assert (trends[0].strong_buy, trends[0].buy, trends[0].hold, trends[0].sell, trends[0].strong_sell) == (12, 22, 15, 3, 1);
    assert trends[0].stamp.published_at == "2026-09-01";
    surprises = eps_surprises("AAPL", budget(), data);
    assert [s.period for s in surprises] == ["2026-06-30", "2026-03-31", "2025-12-31", "2025-09-30"];
    assert (surprises[0].actual, surprises[0].estimate, surprises[0].surprise_percent) == (1.91, 1.9271, -0.8873);
    assert fake.misses == [];
}

test "key metrics keep the chosen few" {
    metrics = key_metrics("AAPL", budget(), client());
    assert metrics is not None;
    assert set(metrics.values) == set(KEY_METRICS);
    assert metrics.values["peTTM"] == 38.2496;
}

test "an unknown symbol has no data rather than an error" {
    data = client();
    fake.script = [(200, {}, "[]"), (200, {}, '{"metric": {}, "series": {}}')];
    assert recommendation_trends("ZZZZQ", budget(), data) == [];
    assert key_metrics("ZZZZQ", budget(), data) is None;
}

test "a premium endpoint's refusal is raised without retrying" {
    data = client();
    fake.script = [(403, {}, '{"error": "You don\'t have access to this resource."}')];
    with testraises(SourceError) as raised {
        eps_surprises("AAPL", budget(), data);
    }
    assert (raised.value as SourceError).status == 403;
    assert len(fake.requests) == 1;
}

test "a missing key is named before any request" {
    saved = os.environ.pop("FINNHUB_API_KEY", None);
    try {
        with testraises(MissingKey, `match="FINNHUB_API_KEY is not set") {
            finnhub_client();
        }
    } finally {
        if saved is not None {
            os.environ["FINNHUB_API_KEY"] = saved;
        }
    }
}
