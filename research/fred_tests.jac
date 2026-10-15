"""The FRED collector against replayed responses. No network and no real key.

The fixtures in tests/fixtures/fred are in the documented observations format
(https://fred.stlouisfed.org/docs/api/fred/series_observations.html), filled with the real
values FRED published through 2026-10-14. They were built by hand because the team had no
FRED key yet (#11); re-record them with COLLECTOR_RECORD_DIR once it does.
"""
import json;
import os;
import tempfile;
import from datetime { datetime, timezone }
import from pathlib { Path }
import from jaclang.data.storage.storage { Storage }
import from research.collector { MissingKey, RawCache, RunBudget, SourceClient, SourceError, TokenBucket }
import from research.fred {
    FRED_ATTRIBUTION,
    FRED_SERIES,
    fred_client,
    macro_series,
    observations,
    series_url
}
import from research.sources { SOURCES }
import from tests.fakes.source_server { FakeSource, serve_source }

glob FIXTURES: Path = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "fred";
glob fake: FakeSource = serve_source(SOURCES["fred"].base_url_env, FIXTURES);
glob AS_OF: str = "2026-10-14";
# The run's morning: every fixture series is fresh then.
glob NOW: datetime = datetime(2026, 10, 14, 11, 30, tzinfo=timezone.utc);

def client -> SourceClient {
    fake.reset();
    return SourceClient(
        source=SOURCES["fred"],
        secrets={"api_key": "test-key"},
        cache=RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage),
        bucket=TokenBucket(per_minute=60000, burst=100),
        backoff_s=0.0
    );
}

def budget -> RunBudget {
    return RunBudget(limits={"fred": 40});
}

test "a daily series skips holidays, is oldest first, and cites the public series page" {
    series = observations("DGS10", "2026-06-16", AS_OF, budget(), client());
    assert fake.misses == [];
    assert series is not None;
    days = [o.day for o in series.observations];
    assert days == sorted(days);
    # Columbus Day: the bond market was closed, and FRED sent ".".
    assert "2026-10-12" not in days;
    assert (series.observations[-1].day, series.latest()) == ("2026-10-13", 5.21);
    assert series.stamp.source_url == "https://fred.stlouisfed.org/series/DGS10";
    assert series.stamp.published_at == "2026-10-13";
    assert series.stamp.dataset == "fred.daily";
}

test "the key is sent as a query parameter but kept out of the citation" {
    data = client();
    observations("DGS2", "2026-06-16", AS_OF, budget(), data);
    assert fake.requests[0].params["api_key"] == "test-key";
    assert fake.requests[0].params["file_type"] == "json";
    assert "api_key" not in series_url("DGS2");
}

test "every series is read as of the run day, with 13 months of monthly data" {
    (found, gaps) = macro_series(AS_OF, budget(), client(), now=NOW);
    assert fake.misses == [] and gaps == [];
    assert [s.id for s in found] == list(FRED_SERIES);
    cpi = [s for s in found if s.id == "CPIAUCSL"][0];
    assert (cpi.observations[0].day, cpi.observations[-1].day) == ("2025-09-01", "2026-09-01");
    # October 2025's CPI was never published (the government shutdown), and FRED sends ".".
    assert len(cpi.observations) == 12 and "2025-10-01" not in [o.day for o in cpi.observations];
    assert cpi.stamp.dataset == "fred.monthly";
}

test "a stale series becomes a gap rather than an input" {
    later = datetime(2026, 10, 30, tzinfo=timezone.utc);
    (found, gaps) = macro_series(AS_OF, budget(), client(), now=later);
    # Daily series age out after five days; September's monthly prints are still fresh.
    assert sorted(s.id for s in found) == ["CPIAUCSL", "UNRATE"];
    assert len(gaps) == 4 and all("older than the 120-hour limit" in g for g in gaps);
}

test "a refused series is a gap, and the rest still arrive" {
    data = client();
    fake.script = [(400, {}, json.dumps({"error_code": 400, "error_message": "Bad Request.  The series does not exist."}))];
    (found, gaps) = macro_series(AS_OF, budget(), data, now=NOW);
    assert len(found) == len(FRED_SERIES) - 1;
    assert len(gaps) == 1 and gaps[0].startswith("fred: DGS2 is unavailable") and "status 400" in gaps[0];
}

test "a range with only missing values has no series" {
    data = client();
    fake.script = [(200, {}, json.dumps({"observations": [{"date": "2026-10-12", "value": "."}]}))];
    assert observations("DGS10", "2026-10-12", "2026-10-12", budget(), data) is None;
}

test "an error page sent with status 200 is refused" {
    data = client();
    fake.script = [(200, {}, "<html>maintenance</html>")];
    with testraises(SourceError, `match="not JSON") {
        observations("VIXCLS", "2026-10-01", AS_OF, budget(), data);
    }
    fake.script = [(200, {}, '{"seriess": []}')];
    with testraises(SourceError, `match="no observations list") {
        observations("VIXCLS", "2026-10-02", AS_OF, budget(), data);
    }
}

test "a missing key is one gap for every series, before any request" {
    saved = os.environ.pop("FRED_API_KEY", None);
    try {
        with testraises(MissingKey, `match="FRED_API_KEY is not set") {
            fred_client();
        }
        fake.reset();
        (found, gaps) = macro_series(AS_OF, budget());
        assert found == [] and len(gaps) == 1 and "FRED_API_KEY is not set" in gaps[0];
        assert fake.requests == [];
    } finally {
        if saved is not None {
            os.environ["FRED_API_KEY"] = saved;
        }
    }
}

test "the attribution FRED requires is shared for the dashboard" {
    assert FRED_ATTRIBUTION == "This product uses the FRED® API but is not endorsed or certified by the Federal Reserve Bank of St. Louis.";
}
