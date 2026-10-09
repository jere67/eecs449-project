"""The Alpaca collector against recorded responses: daily bars, the calendar, latest trades,
and assets. No network and no real keys."""
import json;
import os;
import tempfile;
import from pathlib { Path }
import from jaclang.data.storage.storage { Storage }
import from datetime { datetime }
import from research.alpaca {
    MARKET_TZ,
    alpaca_data_client,
    bars_final,
    assets,
    daily_bars,
    latest_trades,
    market_calendar
}
import from research.collector {
    MissingKey,
    RawCache,
    RunBudget,
    SourceClient,
    SourceError,
    TokenBucket
}
import from research.sources { SOURCES }
import from tests.fakes.source_server { FakeSource, serve_source }

glob FIXTURES: Path = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "alpaca";
glob KEYS: dict[str, str] = {"APCA-API-KEY-ID": "test-key", "APCA-API-SECRET-KEY": "test-secret"};

"""One fake answers both Alpaca hosts; their paths do not overlap."""
def start_alpaca -> FakeSource {
    started = serve_source(SOURCES["alpaca_data"].base_url_env, FIXTURES);
    os.environ[SOURCES["alpaca_trading"].base_url_env] = os.environ[SOURCES["alpaca_data"].base_url_env];
    return started;
}

glob fake: FakeSource = start_alpaca();

def client(source: str = "alpaca_data", cache: RawCache | None = None) -> SourceClient {
    fake.reset();
    return SourceClient(
        source=SOURCES[source],
        headers=KEYS,
        cache=cache or RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage),
        bucket=TokenBucket(per_minute=60000, burst=100),
        backoff_s=0.0
    );
}

def budget -> RunBudget {
    return RunBudget(limits={"alpaca_data": 20, "alpaca_trading": 20});
}

def page(bars: dict[str, list[dict[str, str | float]]], token: str | None) -> str {
    return json.dumps({"bars": bars, "next_page_token": token});
}

def raw_bar(t: str, close: float) -> dict[str, str | float] {
    return {"t": t, "o": close, "h": close, "l": close, "c": close, "v": 100, "n": 3, "vw": close};
}

test "daily bars are read per symbol, oldest first, with a gap for a symbol without any" {
    data = client();
    spent = budget();
    (series, gaps) = daily_bars(["SPY", "AAPL", "BRK.B", "ZZZZQ", "AAPL"], "2026-09-01", "2026-10-07", spent, data);
    assert fake.misses == [];
    assert [s.symbol for s in series] == ["AAPL", "BRK.B", "SPY"];
    assert gaps == ["alpaca.bars: no daily bars for ZZZZQ from 2026-09-01 to 2026-10-07"];
    aapl = series[0];
    assert len(aapl.bars) == 26;
    assert aapl.bars[0].day == "2026-09-01" and aapl.bars[-1].day == "2026-10-07";
    assert aapl.bars[-1].close == 336.67 and aapl.bars[-1].volume == 32251446;
    assert aapl.stamp.published_at == "2026-10-07";
    assert aapl.stamp.source_url.endswith("feed=sip&symbols=AAPL");
    # Keys travel as headers, and the request asks for whole-market, adjusted bars.
    seen = fake.requests[0];
    assert seen.headers["APCA-API-KEY-ID"] == "test-key";
    assert seen.params["feed"] == "sip" and seen.params["adjustment"] == "all";
    assert seen.params["symbols"] == "AAPL,BRK.B,SPY,ZZZZQ";
    assert spent.spent == {"alpaca_data": 1};
}

test "bars ending at a completed session are cached for good" {
    data = client();
    spent = budget();
    daily_bars(["AAPL", "BRK.B", "SPY", "ZZZZQ"], "2026-09-01", "2026-10-07", spent, data);
    daily_bars(["AAPL", "BRK.B", "SPY", "ZZZZQ"], "2026-09-01", "2026-10-07", spent, data);
    assert len(fake.requests) == 1;
}

test "pages are followed and a symbol split across them is joined" {
    data = client();
    fake.script = [
        (200, {}, page({"AAA": [raw_bar("2026-01-02T05:00:00Z", 10.0)]}, "next-1")),
        (200, {}, page({"AAA": [raw_bar("2026-01-05T05:00:00Z", 11.0)], "BBB": [raw_bar("2026-01-05T05:00:00Z", 5.0)]}, None))
    ];
    (series, gaps) = daily_bars(["AAA", "BBB"], "2026-01-01", "2026-01-06", budget(), data);
    assert gaps == [];
    assert [(s.symbol, [b.day for b in s.bars]) for s in series] == [("AAA", ["2026-01-02", "2026-01-05"]), ("BBB", ["2026-01-05"])];
    assert "page_token" not in fake.requests[0].params;
    assert fake.requests[1].params["page_token"] == "next-1";
}

test "bars must end at a completed session" {
    with testraises(ValueError, `match="not a completed session") {
        daily_bars(["AAPL"], "2026-01-01", "2999-01-01", budget(), client());
    }
    # Today's bar is final once extended hours and the SIP delay are over.
    evening = datetime(2026, 10, 8, 20, 15, tzinfo=MARKET_TZ);
    assert bars_final("2026-10-08", evening) and bars_final("2026-10-07", evening);
    assert not bars_final("2026-10-08", evening.replace(hour=20, minute=14));
    assert not bars_final("2026-10-09", evening);
}

test "a refused request is raised without retrying" {
    data = client();
    fake.script = [(403, {}, '{"message": "subscription does not permit querying recent SIP data"}')];
    with testraises(SourceError) as raised {
        daily_bars(["AAPL"], "2026-01-01", "2026-01-06", budget(), data);
    }
    assert (raised.value as SourceError).status == 403;
    assert len(fake.requests) == 1;
}

test "the calendar lists trading days and marks early closes" {
    days = market_calendar("2026-11-20", "2026-12-31", budget(), client("alpaca_trading"));
    assert fake.misses == [];
    assert len(days) == 28;
    assert [d.day for d in days if d.early_close] == ["2026-11-27", "2026-12-24"];
    # Thanksgiving and Christmas are not trading days.
    assert not {"2026-11-26", "2026-12-25"} & {d.day for d in days};
    assert days[0].open == "09:30" and days[0].close == "16:00";
}

test "latest trades are stamped with the trade time" {
    (trades, gaps) = latest_trades(["BRK.B", "AAPL", "ZZZZQ"], budget(), client());
    assert fake.misses == [];
    assert [(t.symbol, t.price) for t in trades] == [("AAPL", 340.43), ("BRK.B", 511.02)];
    assert trades[0].stamp.published_at == trades[0].at == "2026-10-08T19:59:59.912615055Z";
    assert trades[0].stamp.source_url.endswith("symbols=AAPL&feed=iex");
    assert gaps == ["alpaca.latest_trade: no IEX trade for ZZZZQ"];
}

test "assets say which symbols can be traded" {
    listed = assets(budget(), client("alpaca_trading"));
    assert fake.misses == [];
    assert listed["BRK.B"].tradable and listed["BRK.B"].fractionable;
    assert listed["AAPL"].exchange == "NASDAQ";
    assert not listed["IGTAR"].tradable;
}

test "a missing key is named before any request" {
    saved = {name: os.environ.pop(name, None) for name in ["ALPACA_API_KEY", "ALPACA_SECRET_KEY"]};
    try {
        with testraises(MissingKey, `match="ALPACA_API_KEY is not set") {
            alpaca_data_client();
        }
    } finally {
        for (name, value) in saved.items() {
            if value is not None {
                os.environ[name] = value;
            }
        }
    }
}
