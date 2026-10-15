"""The Research phase's glue (run/research.jac): per-ticker collection against recorded SEC
responses with every other source down, the sub-agent fan-out with MockLLM standing in for
the research model, and the graph a finished pass writes. No network."""
import json;
import os;
import tempfile;
import uuid;
import from datetime { datetime, timezone }
import from pathlib { Path }
import from jaclang.byllm.lib { MockLLM, MockRawResponse }
import from jaclang.data.storage.storage { Storage }
import agents.research as research_module;
import research.collector as collector_module;
import from agents.research { MacroResult, ResearchResult }
import from models.agents { Domain, MacroReport, ResearchReport, RiskRegime, Stance }
import from models.graph { CoverageReason, Covers, HasMacro, Portfolio, PortfolioMode, Researched, RunStatus }
import from models.research { RegimeInputs, Stamp }
import from research.alpaca_news { Article }
import from research.briefs { FundamentalsInputs, MacroInputs, MarketInputs, NewsInputs }
import from research.collector { RunBudget }
import from research.finnhub { RecommendationTrend }
import from research.screener { Pick, PickReason, Shortlist }
import from research.sources { DATASETS, SOURCES }
import from run.research {
    Attempts,
    PassConfig,
    PassContext,
    ResearchPass,
    TickerInputs,
    TickerResearch,
    collect_ticker,
    current,
    record_pass,
    sessions_until,
    write_reports
}
import from tests.fakes.source_server { FakeSource }

glob SEC_FIXTURES: Path = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "sec";
glob NOW: datetime = datetime(2026, 10, 15, 12, 0, tzinfo=timezone.utc);
glob AT: str = "2026-10-15T12:00:00+00:00";
glob SESSIONS: list[str] = ["2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-19", "2026-10-20", "2026-10-21"];

def stamp(published: str, url: str = "https://example.com/x", dataset: str = "finnhub.recommendations") -> Stamp {
    return Stamp(source="finnhub", dataset=dataset, source_url=url, published_at=published, fetched_at=AT);
}

def trend(period: str) -> RecommendationTrend {
    return RecommendationTrend(symbol="AAPL", period=period, strong_buy=10, buy=20, hold=10, sell=1, strong_sell=0, stamp=stamp(period));
}

test "sessions until a release count trading days from the run date, not the release day" {
    assert sessions_until(SESSIONS, "2026-10-15", "2026-10-15") == 0;
    assert sessions_until(SESSIONS, "2026-10-15", "2026-10-16") == 1;
    # The weekend is not a session.
    assert sessions_until(SESSIONS, "2026-10-15", "2026-10-19") == 2;
    assert sessions_until(SESSIONS, "2026-10-15", "2026-10-30") is None;
    assert sessions_until([], "2026-10-15", "2026-10-16") is None;
}

test "a history is kept whole while its newest item is fresh, and dropped when it is not" {
    history = [trend("2026-07-01"), trend("2026-10-01"), trend("2026-08-01")];
    assert current(history, DATASETS["finnhub.recommendations"], NOW) == (history, []);
    (kept, gaps) = current([trend("2026-07-01"), trend("2026-08-01")], DATASETS["finnhub.recommendations"], NOW);
    assert kept == [];
    assert len(gaps) == 1 and "published 2026-08-01" in gaps[0];
    assert current([], DATASETS["finnhub.recommendations"], NOW) == ([], []);
}

test "a failed source call is a gap for its brief and a fetch error, never an exception" {
    tries = Attempts();
    gaps: list[str] = [];
    def boom -> int {
        raise KeyError("results");
    }
    assert tries.run("finnhub.metrics", gaps, boom) is None;
    assert tries.run("finnhub.metrics", gaps, lambda { 7; }) == 7;
    assert tries.errors == ["finnhub.metrics: KeyError: 'results'"];
    assert gaps == ["finnhub.metrics: unavailable (KeyError: 'results')"];
}

"""Run `collect_ticker` for AAPL with every source's base URL pointed at one fake that has
only the SEC recordings, so Finnhub and Alpaca answer 404, and a throwaway raw cache so
nothing reaches the real one."""
def collect_aapl(cik: str) -> tuple[TickerInputs, FakeSource] {
    fake = FakeSource();
    url = fake.start();
    fake.load(SEC_FIXTURES);
    names = [s.base_url_env for s in SOURCES.values()] + ["SEC_USER_AGENT", "FINNHUB_API_KEY", "ALPACA_API_KEY", "ALPACA_SECRET_KEY"];
    saved_env = {n: os.environ.get(n) for n in names};
    saved_storage = collector_module.RAW_CACHE.storage;
    for s in SOURCES.values() {
        os.environ[s.base_url_env] = url;
    }
    os.environ.update({"SEC_USER_AGENT": "trading-agent test@example.edu", "FINNHUB_API_KEY": "test", "ALPACA_API_KEY": "test", "ALPACA_SECRET_KEY": "test"});
    collector_module.RAW_CACHE.storage = store(base_path=tempfile.mkdtemp()) as Storage;
    try {
        ctx = PassContext(
            run_day="2026-10-15",
            now=NOW,
            sessions=SESSIONS,
            series={},
            technicals={},
            budget=RunBudget(limits={name: 40 for name in SOURCES}),
            config=PassConfig()
        );
        found = collect_ticker(Pick(symbol="AAPL", sector="Information Technology", reason=PickReason.SCORE, score=1.2), None, cik, ctx);
    } finally {
        collector_module.RAW_CACHE.storage = saved_storage;
        for (n, value) in saved_env.items() {
            if value is None {
                os.environ.pop(n, None);
            } else {
                os.environ[n] = value;
            }
        }
        fake.stop();
    }
    return (found, fake);
}

test "a ticker's SEC data is collected while Finnhub and Alpaca are down" {
    (found, _) = collect_aapl("0000320193");
    funda = found.fundamentals;
    assert funda.sec is not None;
    revenue = funda.sec.get("revenue_quarter");
    assert revenue is not None and revenue.value == 109417000000;
    assert funda.metrics is None and funda.trends == [] and funda.surprises == [];
    assert funda.insider_since == "2026-07-17";
    assert funda.trades is not None and any(t.insider == "Newstead Jennifer" for t in funda.trades);
    # Form 4s outside the trimmed recordings are gaps, not failures.
    assert any(g.startswith("sec.filing: Form 4 ") for g in funda.gaps);
    news = found.news;
    assert [(e.filed, e.items) for e in news.events] == [("2026-09-01", ["5.02"])];
    assert news.release is not None and news.release.filed == "2026-07-30";
    assert news.articles == [] and news.next_earnings is None;
    assert sorted(e.split(":")[0] for e in found.fetch_errors) == [
        "alpaca.news", "finnhub.eps_surprises", "finnhub.metrics", "finnhub.news", "finnhub.recommendations"
    ];
    assert any(g.startswith("finnhub.metrics: unavailable (") for g in funda.gaps);
    assert any(g.startswith("alpaca.news: unavailable (") for g in news.gaps);
    assert found.market.stock is None and found.market.sector_etf == "XLK";
    assert found.market.gaps == ["alpaca.bars: no fresh daily bars for AAPL, so there are no indicators"];
}

test "a ticker without a CIK makes no SEC request and says so in both briefs" {
    (found, fake) = collect_aapl("");
    assert not any("/submissions/" in r.path or "/api/xbrl/" in r.path for r in fake.requests);
    assert "sec: no CIK for AAPL" in found.fetch_errors;
    assert found.fundamentals.sec is None and found.fundamentals.trades is None;
    assert any(g.startswith("sec: no CIK for AAPL") for g in found.news.gaps);
}

glob ARTICLE_URL: str = "https://www.benzinga.com/news/26/10/2";

def collected(symbol: str) -> TickerInputs {
    article = Article(
        id=2,
        headline="Megacaps rally",
        summary="Apple and Microsoft led the index higher.",
        content="",
        author="",
        source="benzinga",
        url=ARTICLE_URL,
        symbols=["AAPL", "MSFT"],
        created_at="2026-10-14T20:00:00Z",
        updated_at="2026-10-14T20:00:00Z",
        stamp=stamp("2026-10-14T20:00:00Z", ARTICLE_URL, "alpaca.news")
    );
    return TickerInputs(
        pick=Pick(symbol=symbol, sector="Information Technology", reason=PickReason.SCORE),
        market=MarketInputs(),
        fundamentals=FundamentalsInputs(),
        news=NewsInputs(articles=[article]),
        fetch_errors=[f"finnhub.metrics: down for {symbol}"]
    );
}

test "every ticker gets its three reports in order, and briefs without sources make no request" {
    content = json.dumps(
        {
            "summary": "The megacaps rallied.",
            "view": "BUY",
            "confidence": 0.5,
            "evidence": [{"claim": "Megacaps led the index.", "source_url": ARTICLE_URL, "published": "x"}],
            "risks": [],
            "data_gaps": []
        }
    );
    mock = MockLLM(model_name="mock-primary", config={"outputs": [MockRawResponse(content=content), MockRawResponse(content=content)]});
    saved = research_module.research_llm;
    setattr(research_module, "research_llm", mock);
    try {
        (tickers, macro) = write_reports("2026-10-15", [collected("AAPL"), collected("MSFT")], MacroInputs());
    } finally {
        setattr(research_module, "research_llm", saved);
    }
    # Only the two news briefs had sources: market, fundamentals, and macro fell back unasked.
    assert len(mock.seen_prompts) == 2;
    assert [t.pick.symbol for t in tickers] == ["AAPL", "MSFT"];
    for t in tickers {
        assert [(r.ticker, r.domain) for r in t.reports] == [(t.pick.symbol, Domain.MARKET), (t.pick.symbol, Domain.FUNDAMENTALS), (t.pick.symbol, Domain.NEWS)];
        assert [r.complete() for r in t.reports] == [False, False, True];
        assert t.fetch_errors == [f"finnhub.metrics: down for {t.pick.symbol}"];
    }
    assert not macro.ok and macro.error == "no sources were collected";
    assert macro.body.regime == RiskRegime.NEUTRAL;
}

def result(symbol: str, domain: Domain, cited: int, dropped: int, ok: bool = True) -> ResearchResult {
    body = ResearchReport(summary=f"{symbol} {domain.value}", view=Stance.HOLD, confidence=0.4);
    return ResearchResult(ticker=symbol, domain=domain, body=body, model="mock-primary" if ok else "", ok=ok, cited=cited, dropped_citations=dropped);
}

def finished_pass -> ResearchPass {
    picks = [
        Pick(symbol="AAPL", sector="Information Technology", reason=PickReason.SCORE, score=1.5),
        Pick(symbol="XOM", sector="Energy", reason=PickReason.OPEN_POSITION, note="held")
    ];
    macro = MacroResult(body=MacroReport(summary="Calm.", regime=RiskRegime.RISK_ON, confidence=0.6), model="mock-primary", cited=2, dropped_citations=0);
    return ResearchPass(
        run_day="2026-10-15",
        started_at=AT,
        finished_at="2026-10-15T12:20:00+00:00",
        shortlist=Shortlist(picks=picks, scores=[], excluded={}),
        tickers=[
            TickerResearch(pick=picks[0], reports=[result("AAPL", Domain.MARKET, 3, 1), result("AAPL", Domain.FUNDAMENTALS, 4, 0), result("AAPL", Domain.NEWS, 0, 0, ok=False)]),
            TickerResearch(pick=picks[1], reports=[result("XOM", Domain.MARKET, 2, 0), result("XOM", Domain.FUNDAMENTALS, 1, 0), result("XOM", Domain.NEWS, 2, 1)], fetch_errors=["sec.form4: down"])
        ],
        macro=macro,
        regime=RegimeInputs(spy_close=650.0, spy_sma_200=600.0, spy_vol_20=0.14, spy_as_of="2026-10-14"),
        phase_seconds={"screen": 60.0, "collect": 90.0, "research": 300.0},
        model_requests=6
    );
}

test "a pass reports its completeness and citation rate for the exit criterion" {
    done = finished_pass();
    assert done.completeness() == 5 / 6;
    # 12 per-ticker claims cited plus 2 macro, out of 16 made.
    assert done.citation_rate() == 14 / 16;
    assert done.seconds() == 450.0;
}

test "a finished pass is written as a run with coverage, reports, and the macro record" {
    team = Portfolio(name=f"test-{uuid.uuid4()}", mode=PortfolioMode.AUTO, starting_cash=100000.0, opened_at=AT);
    root ++> team;
    run = record_pass(team, finished_pass());
    assert (run.run_date, run.status, run.model_requests) == ("2026-10-15", RunStatus.NORMAL, 6);
    assert run.summary == "Research: 2 tickers, 83% of reports complete, 88% of claims cited.";
    assert run.model_versions["screen"] == "2026-10-08.1";
    macro = [run ->:HasMacro:->][0];
    assert macro.inputs is not None and macro.inputs.spy_above_200d();
    assert macro.body.regime == RiskRegime.RISK_ON;
    covered = [run ->:Covers:->];
    assert [(c.ticker, c.reason, c.screen_score) for c in covered] == [("AAPL", CoverageReason.SCREEN, 1.5), ("XOM", CoverageReason.HELD, 0.0)];
    assert covered[1].fetch_errors == ["sec.form4: down"] and covered[1].reason_note == "held";
    records = [covered[0] ->:Researched:->];
    assert [(r.domain, r.model) for r in records] == [(Domain.MARKET, "mock-primary"), (Domain.FUNDAMENTALS, "mock-primary"), (Domain.NEWS, "")];
    assert all(r.as_of == "2026-10-15T12:20:00+00:00" for r in records);
}
