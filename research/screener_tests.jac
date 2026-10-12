"""The screen's rules on hand-built universes, property checks over seeded random ones, and
`gather` against a scripted fake of every source. No network."""
import json;
import math;
import os;
import random;
import tempfile;
import from datetime { date, timedelta }
import from jaclang.data.storage.storage { Storage }
import from models.research { Stamp }
import from research.collector { RawCache, RunBudget, SourceClient, TokenBucket }
import from research.screener {
    Candidate,
    PickReason,
    ScreenConfig,
    ScreenSources,
    Wildcard,
    add_wildcards,
    gather,
    screen,
    zscores
}
import from research.sources { SOURCES }
import from research.wikipedia { Constituent }
import from tests.fakes.source_server { FakeSource }

glob SECTORS: list[str] = ["Energy", "Financials", "Health Care", "Industrials", "Information Technology", "Utilities"];

def candidate(symbol: str, sector: str = "Energy", momentum: float = 0.0, volume: float = 1e8, tradable: bool = True) -> Candidate {
    return Candidate(
        symbol=symbol,
        name=symbol,
        company=symbol,
        sector=sector,
        tradable=tradable,
        momentum_20=momentum,
        momentum_60=momentum,
        rvol_5=1.0,
        vol_20=0.2,
        dollar_volume_20=volume,
        news_3=0,
        earnings_soon=False
    );
}

def random_universe(rng: random.Random, size: int) -> list[Candidate] {
    return [
        Candidate(
            symbol=f"S{i:03d}",
            name="",
            company=f"C{i // 2 if i % 10 == 0 else i:03d}",
            sector=rng.choice(SECTORS),
            tradable=rng.random() > 0.02,
            momentum_20=rng.gauss(0, 0.05) if rng.random() > 0.05 else None,
            momentum_60=rng.gauss(0, 0.1) if rng.random() > 0.05 else None,
            rvol_5=rng.lognormvariate(0, 0.3),
            vol_20=rng.lognormvariate(-1.5, 0.4),
            dollar_volume_20=rng.lognormvariate(19, 1.2) if rng.random() > 0.01 else None,
            news_3=rng.randint(0, 20),
            earnings_soon=rng.random() < 0.05
        )
        for i in range(size)
    ];
}

test "z-scores use the population deviation and score a missing value 0" {
    assert zscores([1.0, 3.0, None]) == [-1.0, 1.0, 0.0];
    assert zscores([2.0, 2.0]) == [0.0, 0.0];
    assert zscores([5.0, None]) == [0.0, 0.0];
}

test "the score adds each weighted term" {
    a = candidate("AAA", momentum=0.1);
    b = candidate("BBB", momentum=-0.1);
    b.earnings_soon = True;
    b.news_3 = 4;
    result = screen([a, b], []);
    rows = {r.symbol: r for r in result.scores};
    # Two names: every feature with spread has z = +1 or -1.
    assert rows["AAA"].terms == {"momentum_20": 1.0, "momentum_60": 1.0, "rvol_5": 0.0, "news_3": -1.0, "vol_20": -0.0, "earnings_soon": 0.0};
    assert rows["AAA"].score == 1.0 and rows["BBB"].score == 0.0;
    assert result.symbols() == ["AAA", "BBB"];
}

test "illiquid, untradable, and short-history names are excluded with a reason" {
    short = candidate("NEW");
    short.dollar_volume_20 = None;
    result = screen([candidate("OK"), candidate("THIN", volume=4e7), candidate("HALT", tradable=False), short], []);
    assert result.symbols() == ["OK"];
    assert result.excluded == {
        "HALT": "not tradable on Alpaca",
        "NEW": "under 20 sessions of history",
        "THIN": "20-day dollar volume $40.0M is under $50M"
    };
}

test "no sector fills more than three places" {
    names = [candidate(f"E{i}", "Energy", momentum=1.0 + i) for i in range(6)] + [candidate(f"U{i}", "Utilities", momentum=-1.0) for i in range(2)];
    result = screen(names, [], ScreenConfig(shortlist_size=5));
    assert result.symbols() == ["E5", "E4", "E3", "U0", "U1"];
}

test "only the higher-scoring share class of a company is picked" {
    goog = candidate("GOOG", "Communication Services", momentum=1.0);
    googl = candidate("GOOGL", "Communication Services", momentum=2.0);
    goog.company = "0001652044";
    googl.company = "0001652044";
    result = screen([goog, googl, candidate("XOM")], []);
    assert result.symbols() == ["GOOGL", "XOM"];
    assert result.excluded == {"GOOG": "another share class of the same company, GOOGL, scored higher"};
}

test "open positions are always appended, even outside the index" {
    result = screen([candidate("AAA"), candidate("BBB")], ["ZZZ", "AAA", "ZZZ"], ScreenConfig(shortlist_size=1));
    # AAA and BBB score the same, so the symbol breaks the tie.
    assert [(p.symbol, p.reason) for p in result.picks] == [("AAA", PickReason.SCORE), ("ZZZ", PickReason.OPEN_POSITION)];
    result = screen([candidate("AAA"), candidate("BBB")], ["BBB"], ScreenConfig(shortlist_size=1));
    assert [(p.symbol, p.reason) for p in result.picks] == [("AAA", PickReason.SCORE), ("BBB", PickReason.OPEN_POSITION)];
}

test "random universes keep every rule, and input order never matters" {
    for seed in range(200) {
        rng = random.Random(seed);
        universe = random_universe(rng, rng.randint(5, 120));
        positions = [c.symbol for c in rng.sample(universe, rng.randint(0, 4))] + (["OUTSIDE"] if seed % 7 == 0 else []);
        result = screen(universe, positions);
        scored = [p for p in result.picks if p.reason == PickReason.SCORE];
        assert len(scored) <= 15, seed;
        per_sector: dict[str, int] = {};
        for pick in scored {
            per_sector[pick.sector] = per_sector.get(pick.sector, 0) + 1;
        }
        assert all(n <= 3 for n in per_sector.values()), seed;
        assert set(positions) <= set(result.symbols()), seed;
        assert len(result.symbols()) == len(set(result.symbols())), seed;
        by_company = {c.symbol: c.company for c in universe};
        companies = [by_company[p.symbol] for p in scored];
        assert len(companies) == len(set(companies)), seed;
        ranked = [p.score or 0.0 for p in scored];
        assert ranked == sorted(ranked, reverse=True), seed;
        assert all(math.isfinite(r.score) for r in result.scores), seed;
        shuffled = list(universe);
        rng.shuffle(shuffled);
        assert screen(shuffled, list(reversed(positions))).symbols() == result.symbols(), seed;
    }
}

test "the screen fills its places when enough sectors are liquid" {
    rng = random.Random(7);
    universe = random_universe(rng, 400);
    for c in universe {
        c.tradable = True;
        c.dollar_volume_20 = 1e8;
    }
    assert len(screen(universe, []).picks) == 15;
}

test "wildcards need a reason, are not repeated, and stop at three" {
    result = screen([candidate("AAA")], []);
    refused = add_wildcards(
        result,
        [Wildcard(symbol="W1", reason="Fed surprise"), Wildcard(symbol="AAA", reason="dup"), Wildcard(symbol="W2", reason=" "), Wildcard(symbol="W3", reason="r"), Wildcard(symbol="W4", reason="r"), Wildcard(symbol="W5", reason="r")]
    );
    assert [p.symbol for p in result.picks if p.reason == PickReason.WILDCARD] == ["W1", "W3", "W4"];
    assert result.picks[1].note == "Fed surprise";
    assert refused == ["AAA: already on the shortlist", "W2: a wildcard needs a reason", "W5: at most 3 wildcards a run"];
}

"""A fake answering every source, and clients for it with no waiting."""
def scripted_sources -> tuple[FakeSource, ScreenSources] {
    fake = FakeSource();
    url = fake.start();
    for name in ["alpaca_data", "alpaca_trading", "finnhub"] {
        os.environ[SOURCES[name].base_url_env] = url;
    }
    def client(name: str) -> SourceClient {
        return SourceClient(
            source=SOURCES[name],
            cache=RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage),
            bucket=TokenBucket(per_minute=60000, burst=100),
            backoff_s=0.0
        );
    }
    return (fake, ScreenSources(alpaca_data=client("alpaca_data"), alpaca_trading=client("alpaca_trading"), finnhub=client("finnhub")));
}

def member(symbol: str, sector: str) -> Constituent {
    return Constituent(
        symbol=symbol,
        name=symbol,
        sector=sector,
        sub_industry="",
        cik=f"cik-{symbol}",
        date_added="",
        stamp=Stamp(source="wikipedia", dataset="wikipedia.constituents", source_url="", published_at="", fetched_at="")
    );
}

"""Weekday sessions from September 17 to October 29, 2026, as the calendar returns them."""
def calendar_body -> str {
    start = date(2026, 9, 17);
    days = [start + timedelta(days=i) for i in range(43)];
    return json.dumps([{"date": d.isoformat(), "open": "09:30", "close": "16:00"} for d in days if d.weekday() < 5]);
}

def bars_body(volume: float) -> list[dict[str, str | float]] {
    start = date(2026, 8, 20);
    days = [start + timedelta(days=i) for i in range(49)];
    return [
        {"t": f"{d.isoformat()}T04:00:00Z", "o": 100.0, "h": 101.0, "l": 99.0, "c": 100.0 + i, "v": volume, "n": 1, "vw": 100.0}
        for (i, d) in enumerate(x for x in days if x.weekday() < 5)
    ];
}

def gather_script(news: tuple[int, str]) -> list[tuple[int, dict[str, str], str]] {
    return [
        (200, {}, calendar_body()),
        (200, {}, json.dumps([{"symbol": "AAA", "tradable": True}, {"symbol": "BBB", "tradable": True}])),
        (200, {}, json.dumps({"bars": {"AAA": bars_body(1e6), "BBB": bars_body(1e3)}, "next_page_token": None})),
        (news[0], {}, news[1]),
        (200, {}, json.dumps({"earningsCalendar": [{"symbol": "AAA", "date": "2026-10-09"}, {"symbol": "OTHER", "date": "2026-10-09"}]}))
    ];
}

test "gather reads each source for the run's sessions" {
    (fake, sources) = scripted_sources();
    try {
        news = json.dumps({"news": [{"id": 1, "symbols": ["AAA"]}, {"id": 2, "symbols": ["AAA", "BBB"]}], "next_page_token": None});
        fake.script = gather_script((200, news));
        members = [member("AAA", "Energy"), member("BBB", "Energy"), member("CCC", "Utilities")];
        (candidates, gaps) = gather("2026-10-08", members, RunBudget(limits={"alpaca_data": 10, "alpaca_trading": 10, "finnhub": 10}), sources);
    } finally {
        fake.stop();
    }
    seen = fake.requests;
    assert [r.path for r in seen] == ["/v2/calendar", "/v2/assets", "/v2/stocks/bars", "/v1beta1/news", "/calendar/earnings"];
    # Bars end at the close of extended hours on the last session, 20:00 in New York.
    assert (seen[2].params["start"], seen[2].params["end"]) == ("2025-10-06", "2026-10-08T00:00:00Z");
    assert seen[3].params["start"] == "2026-10-05";
    assert (seen[4].params["from"], seen[4].params["to"]) == ("2026-10-08", "2026-10-14");
    assert gaps == ["alpaca.bars: no daily bars for CCC from 2025-10-06 to 2026-10-07"];
    by_symbol = {c.symbol: c for c in candidates};
    assert (by_symbol["AAA"].news_3, by_symbol["AAA"].earnings_soon, by_symbol["AAA"].tradable) == (2, True, True);
    assert (by_symbol["BBB"].news_3, by_symbol["BBB"].earnings_soon) == (1, False);
    assert by_symbol["AAA"].momentum_20 is not None and by_symbol["AAA"].dollar_volume_20 is not None;
    assert not by_symbol["CCC"].tradable and by_symbol["CCC"].dollar_volume_20 is None;
    assert screen(candidates, []).symbols() == ["AAA"];
}

test "a news outage becomes a gap and a zero news term" {
    (fake, sources) = scripted_sources();
    try {
        script = gather_script((500, "down"));
        # The client retries a 5xx three times before giving up.
        fake.script = script[:4] + [(500, {}, "down")] * 3 + script[4:];
        (candidates, gaps) = gather("2026-10-08", [member("AAA", "Energy")], RunBudget(limits={"alpaca_data": 10, "alpaca_trading": 10, "finnhub": 10}), sources);
    } finally {
        fake.stop();
    }
    assert candidates[0].news_3 == 0 and candidates[0].earnings_soon;
    assert any(g.startswith("screener: news counts are unavailable") for g in gaps);
}
