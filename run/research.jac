"""The Research phase of a run (TDD §4 7:32 to 8:10 a.m., §5, §6): screen the S&P 500, collect
each shortlisted ticker's data in parallel, run the Market, Fundamentals, and News
sub-agents on every ticker and the Macro sub-agent once, and record the results.

Collectors and sub-agents run on worker threads, which lose the request's graph context, so
`research_pass` only returns values; `record_pass` writes them to the graph afterwards, on
the caller's thread (TDD §3, rule 6). A failed source becomes a gap,
and a failed sub-agent a safe default, so one bad ticker or provider never stops the pass.
"""
import time;
import from concurrent.futures { Future }
import from datetime { date, datetime, timedelta }
import from agents.models { FALLBACK_MODEL, LIMITER, PRIMARY_MODEL }
import from agents.research { MacroResult, ResearchResult, macro_research, research }
import from models.graph {
    Coverage,
    CoverageReason,
    Covers,
    HasMacro,
    MacroRecord,
    Portfolio,
    Ran,
    Researched,
    ResearchRecord,
    Run,
    RunStatus
}
import from models.research { RegimeInputs, Stamped }
import from research.alpaca { BarSeries, daily_bars, market_calendar }
import from research.alpaca_news { Article, articles }
import from research.briefs {
    Brief,
    FundamentalsInputs,
    MacroInputs,
    MarketInputs,
    NewsInputs,
    fundamentals_brief,
    macro_brief,
    market_brief,
    news_brief,
    regime_inputs
}
import from research.collector { RunBudget, parse_utc, run_budget, split_fresh, utc_now }
import from research.finnhub {
    EarningsDate,
    company_news,
    earnings_calendar,
    eps_surprises,
    key_metrics,
    recommendation_trends
}
import from research.indicators { BOND_BENCHMARKS, BOND_ETFS, SECTOR_ETFS, Technicals, summarize }
import from research.screener { Pick, PickReason, ScreenConfig, Shortlist, gather, screen }
import from research.sec { cik_map, earnings_release, eight_ks, filings, fundamentals, insider_trades }
import from research.sources { DATASETS, Dataset, SOURCES_VERSION }
import from research.wikipedia { Constituent, constituents }
import from run.public { public }
import from run.workers { NETWORK }

glob BENCHMARK: str = "SPY";

glob COVERAGE_REASONS: dict[PickReason, CoverageReason] = {
    PickReason.SCORE: CoverageReason.SCREEN,
    PickReason.OPEN_POSITION: CoverageReason.HELD,
    PickReason.WILDCARD: CoverageReason.WILDCARD
};

"""How far back each source looks in one pass, in calendar days."""
obj PassConfig {
    has screen: ScreenConfig = ScreenConfig(),
        news_days: int = 7,
        events_days: int = 60,
        release_days: int = 100,
        insider_days: int = 90,
        earnings_ahead_days: int = 30,
        articles_per_source: int = 10;
}

"""What every ticker's collection shares: the run date, the trading sessions around it, the
fresh bars and benchmark indicators, the run's source budget, and the clock freshness is
measured against (the pass's start, so every ticker is judged at the same moment)."""
obj PassContext {
    has run_day: str,
        now: datetime,
        sessions: list[str],
        series: dict[str, BarSeries],
        technicals: dict[str, Technicals],
        budget: RunBudget,
        config: PassConfig;

    def since(days: int) -> str {
        return (date.fromisoformat(self.run_day) - timedelta(days=days)).isoformat();
    }
}

"""What the collectors found for one ticker's three briefs, and which sources failed."""
obj TickerInputs {
    has pick: Pick,
        market: MarketInputs,
        fundamentals: FundamentalsInputs,
        news: NewsInputs;
    has fetch_errors: list[str] = [];
}

"""One ticker's research: its pick, its three reports, and the sources that failed."""
obj TickerResearch {
    has pick: Pick,
        reports: list[ResearchResult];
    has fetch_errors: list[str] = [];
}

"""Everything one pass produced, with the figures the Research exit criterion checks
(TDD §1 success criteria)."""
obj ResearchPass {
    has run_day: str,
        started_at: str,
        finished_at: str,
        shortlist: Shortlist,
        tickers: list[TickerResearch],
        macro: MacroResult,
        regime: RegimeInputs;
    has gaps: list[str] = [],
        phase_seconds: dict[str, float] = {},
        model_requests: int = 0,
        fallbacks: int = 0,
        source_calls: dict[str, int] = {};

    def reports -> list[ResearchResult] {
        return [r for t in self.tickers for r in t.reports];
    }

    """Share of per-ticker reports that are complete: the agent answered and cited a source."""
    def completeness -> float {
        found = self.reports();
        return len([r for r in found if r.complete()]) / len(found) if found else 0.0;
    }

    """Share of the claims the models made, macro included, that cite a source in their brief.
    The rest were removed before anything downstream read them."""
    def citation_rate -> float {
        found = self.reports();
        cited = sum(r.cited for r in found) + self.macro.cited;
        made = cited + sum(r.dropped_citations for r in found) + self.macro.dropped_citations;
        return cited / made if made else 0.0;
    }

    def seconds -> float {
        return sum(self.phase_seconds.values());
    }
}

"""The research for a run trading on `run_day` (ISO date), covering the screen's shortlist
and every symbol in `open_positions`. Never touches the graph; pass the result to
`record_pass`."""
def research_pass(run_day: str, open_positions: list[str], config: PassConfig = PassConfig()) -> ResearchPass {
    now = utc_now();
    phases: dict[str, float] = {};
    (requests_before, fallbacks_before) = (LIMITER.sent, LIMITER.fallbacks);
    budget = run_budget();
    gaps: list[str] = [];

    clock = time.monotonic();
    members = constituents(budget);
    (candidates, screen_gaps) = gather(run_day, members, budget, config=config.screen);
    gaps.extend(screen_gaps);
    shortlist = screen(candidates, open_positions, config.screen);
    phases["screen"] = time.monotonic() - clock;

    clock = time.monotonic();
    day = date.fromisoformat(run_day);
    sessions = [
        d.day
        for d in market_calendar((day - timedelta(days=14)).isoformat(), (day + timedelta(days=config.earnings_ahead_days + 14)).isoformat(), budget)
    ];
    last_session = [s for s in sessions if s < run_day][-1];
    symbols = shortlist.symbols();
    wanted = sorted(set(symbols) | {BENCHMARK} | set(SECTOR_ETFS.values()) | set(BOND_ETFS));
    year_ago = (date.fromisoformat(last_session) - timedelta(days=366)).isoformat();
    (bars, bar_gaps) = daily_bars(wanted, year_ago, last_session, budget);
    (fresh, stale) = split_fresh(bars, DATASETS["alpaca.bars"], now);
    gaps.extend(bar_gaps + stale);
    series = {s.symbol: s for s in fresh};
    spy = series.get(BENCHMARK);
    technicals = {
        etf: summarize(series[etf], spy, series.get(BOND_BENCHMARKS.get(etf, "")))
        for etf in [BENCHMARK] + sorted(SECTOR_ETFS.values()) + list(BOND_ETFS)
        if etf in series
    };
    ctx = PassContext(run_day=run_day, now=now, sessions=sessions, series=series, technicals=technicals, budget=budget, config=config);
    (releases, calendar_gaps) = next_releases(ctx);
    gaps.extend(calendar_gaps);
    ciks = company_ciks(symbols, members, budget, gaps);
    pending = [NETWORK.submit(collect_ticker, p, releases.get(p.symbol), ciks.get(p.symbol, ""), ctx) for p in shortlist.picks];
    collected = [f.result() for f in pending];
    phases["collect"] = time.monotonic() - clock;

    clock = time.monotonic();
    macro_inputs = MacroInputs(
        spy=technicals.get(BENCHMARK),
        bonds={etf: technicals[etf] for etf in BOND_ETFS if etf in technicals},
        sectors={etf: technicals[etf] for etf in SECTOR_ETFS.values() if etf in technicals}
    );
    (per_ticker, macro) = write_reports(run_day, collected, macro_inputs);
    phases["research"] = time.monotonic() - clock;

    return ResearchPass(
        run_day=run_day,
        started_at=now.isoformat(),
        finished_at=utc_now().isoformat(),
        shortlist=shortlist,
        tickers=per_ticker,
        macro=macro,
        regime=regime_inputs(macro_inputs),
        gaps=gaps,
        phase_seconds=phases,
        model_requests=LIMITER.sent - requests_before,
        fallbacks=LIMITER.fallbacks - fallbacks_before,
        source_calls=dict(budget.spent)
    );
}

"""Run the three research sub-agents on every collected ticker and the Macro sub-agent
once, all at the same time; the shared limiter paces their requests."""
def write_reports(run_day: str, collected: list[TickerInputs], macro_inputs: MacroInputs) -> tuple[list[TickerResearch], MacroResult] {
    pending_macro = NETWORK.submit(macro_research, macro_brief(run_day, macro_inputs));
    running: list[list[Future[ResearchResult]]] = [];
    for c in collected {
        briefs = [
            market_brief(c.pick.symbol, run_day, c.market),
            fundamentals_brief(c.pick.symbol, run_day, c.fundamentals),
            news_brief(c.pick.symbol, run_day, c.news)
        ];
        running.append([NETWORK.submit(research, b) for b in briefs]);
    }
    per_ticker = [
        TickerResearch(pick=c.pick, reports=[f.result() for f in futures], fetch_errors=c.fetch_errors)
        for (c, futures) in zip(collected, running)
    ];
    return (per_ticker, pending_macro.result());
}

"""Runs source calls for one ticker, turning each failure into a gap for the brief that
needed the data and a fetch error on the ticker's coverage. A parser that trips on an
unexpected response fails the same way, so one ticker's data never stops the pass."""
obj Attempts {
    has errors: list[str] = [];

    def run[T](what: str, gaps: list[str], fetch: Callable[[], T]) -> T | None {
        try {
            return fetch();
        } except Exception as e {
            reason = f"{type(e).__name__}: {str(e)[:300]}";
            self.errors.append(f"{what}: {reason}");
            gaps.append(f"{what}: unavailable ({reason})");
            return None;
        }
    }
}

"""Every input one ticker's three sub-agents read. `release` is its next scheduled earnings
release, and `cik` its SEC company number ("" when unknown)."""
def collect_ticker(pick: Pick, release: EarningsDate | None, cik: str, ctx: PassContext) -> TickerInputs {
    (symbol, budget, config) = (pick.symbol, ctx.budget, ctx.config);
    tries = Attempts();

    sector_etf = SECTOR_ETFS.get(pick.sector, "");
    market = MarketInputs(spy=ctx.technicals.get(BENCHMARK), sector=ctx.technicals.get(sector_etf), sector_etf=sector_etf);
    if symbol in ctx.series {
        market.stock = summarize(ctx.series[symbol], ctx.series.get(BENCHMARK), ctx.series.get(sector_etf));
    } else {
        market.gaps.append(f"alpaca.bars: no fresh daily bars for {symbol}, so there are no indicators");
    }

    funda = FundamentalsInputs(insider_since=ctx.since(config.insider_days));
    funda.metrics = tries.run("finnhub.metrics", funda.gaps, lambda { key_metrics(symbol, budget); });
    (funda.trends, trend_gaps) = current(tries.run("finnhub.recommendations", funda.gaps, lambda { recommendation_trends(symbol, budget); }) or [], DATASETS["finnhub.recommendations"], ctx.now);
    (funda.surprises, surprise_gaps) = current(tries.run("finnhub.eps_surprises", funda.gaps, lambda { eps_surprises(symbol, budget); }) or [], DATASETS["finnhub.eps_surprises"], ctx.now);
    funda.gaps.extend(trend_gaps + surprise_gaps);

    news = NewsInputs(next_earnings=release, sessions_until=sessions_until(ctx.sessions, ctx.run_day, release.day) if release else None);
    found: list[Article] = [];
    found.extend(tries.run("alpaca.news", news.gaps, lambda { articles(symbol, ctx.since(config.news_days), budget, limit=config.articles_per_source); }) or []);
    found.extend(tries.run("finnhub.news", news.gaps, lambda { company_news(symbol, ctx.since(config.news_days), ctx.run_day, budget, limit=config.articles_per_source); }) or []);
    (news.articles, stale_articles) = split_fresh(found, DATASETS["alpaca.news"], ctx.now);
    if stale_articles {
        news.gaps.append(f"news: {len(stale_articles)} articles were past the {DATASETS['alpaca.news'].max_age_hours / 24:g}-day freshness limit and were excluded");
    }

    if not cik {
        tries.errors.append(f"sec: no CIK for {symbol}");
        funda.gaps.append(f"sec: no CIK for {symbol}, so there are no filings or reported figures");
        news.gaps.append(f"sec: no CIK for {symbol}, so there are no 8-K events or earnings release");
        return TickerInputs(pick=pick, market=market, fundamentals=funda, news=news, fetch_errors=tries.errors);
    }
    listed = tries.run("sec.submissions", news.gaps, lambda { filings(symbol, cik, budget); });
    if listed is not None {
        company_filings = listed[1];
        news.events = eight_ks(company_filings, ctx.since(config.events_days));
        news.release = tries.run("sec.earnings_release", news.gaps, lambda { earnings_release(symbol, company_filings, ctx.since(config.release_days), budget); });
        traded = tries.run("sec.form4", funda.gaps, lambda { insider_trades(symbol, company_filings, funda.insider_since, budget); });
        if traded is not None {
            funda.trades = traded[0];
            funda.gaps.extend(traded[1]);
        }
    } else {
        funda.gaps.append("sec.submissions: unavailable, so there is no insider activity");
    }
    facts = tries.run("sec.companyfacts", funda.gaps, lambda { fundamentals(symbol, cik, budget); });
    if facts is not None and facts[0] is not None {
        (kept, stale_facts) = split_fresh([facts[0]], DATASETS["sec.companyfacts"], ctx.now);
        funda.sec = kept[0] if kept else None;
        funda.gaps.extend(facts[1] + stale_facts);
    } elif facts is not None {
        funda.gaps.extend(facts[1]);
    }
    return TickerInputs(pick=pick, market=market, fundamentals=funda, news=news, fetch_errors=tries.errors);
}

"""A history kept whole when its newest item is fresh for `dataset`, and dropped with a gap
when it is not: older items are context for the newest, never a reading on their own."""
def current[T: Stamped](items: list[T], dataset: Dataset, now: datetime) -> tuple[list[T], list[str]] {
    if not items {
        return ([], []);
    }
    newest = max(items, key=lambda (i: T) { parse_utc(i.stamp.published_at); });
    (fresh, stale) = split_fresh([newest], dataset, now);
    return (items, []) if fresh else ([], stale);
}

"""Trading sessions from `run_day` up to, not including, `release_day` (0 when it reports on
the run date), or None when the calendar does not reach it."""
def sessions_until(sessions: list[str], run_day: str, release_day: str) -> int | None {
    if not sessions or release_day > sessions[-1] {
        return None;
    }
    return len([s for s in sessions if run_day <= s < release_day]);
}

"""Each symbol's next earnings release within `earnings_ahead_days` of the run date, from one
calendar read for the whole index."""
def next_releases(ctx: PassContext) -> tuple[dict[str, EarningsDate], list[str]] {
    end = (date.fromisoformat(ctx.run_day) + timedelta(days=ctx.config.earnings_ahead_days)).isoformat();
    try {
        (releases, gaps) = earnings_calendar(ctx.run_day, end, ctx.budget);
    } except Exception as e {
        return ({}, [f"finnhub.earnings_calendar: unavailable, so no ticker shows a scheduled release ({type(e).__name__}: {e})"]);
    }
    nearest: dict[str, EarningsDate] = {};
    for r in sorted(releases, key=lambda (r: EarningsDate) { r.day; }) {
        nearest.setdefault(r.symbol, r);
    }
    return (nearest, gaps);
}

"""SEC company numbers for `symbols`: from the constituents table, then SEC's own ticker map
for any symbol the table lacks. A failure adds to `gaps`."""
def company_ciks(symbols: list[str], members: list[Constituent], budget: RunBudget, gaps: list[str]) -> dict[str, str] {
    found = {m.symbol: m.cik for m in members if m.symbol in symbols and m.cik};
    missing = [s for s in symbols if s not in found];
    if missing {
        try {
            listed = cik_map(budget);
            found.update({s: listed[s] for s in missing if s in listed});
        } except Exception as e {
            gaps.append(f"sec.tickers: unavailable, so {', '.join(missing)} have no SEC data ({type(e).__name__}: {e})");
        }
    }
    return found;
}

"""Write a finished pass under `portfolio`: one Run, a Coverage per ticker with its three
ResearchRecords, and the MacroRecord, each granted READ. Call it after the pass, on the
caller's thread, never on a worker thread."""
def record_pass(portfolio: Portfolio, result: ResearchPass) -> Run {
    run = public(portfolio +>:Ran():+> Run(
        run_date=result.run_day,
        started_at=result.started_at,
        status=RunStatus.NORMAL,
        finished_at=result.finished_at,
        summary=f"Research: {len(result.tickers)} tickers, {result.completeness():.0%} of reports complete, {result.citation_rate():.0%} of claims cited.",
        model_versions={"primary": PRIMARY_MODEL, "fallback": FALLBACK_MODEL, "sources": SOURCES_VERSION, "screen": result.shortlist.version},
        model_requests=result.model_requests
    ));
    public(run +>:HasMacro():+> MacroRecord(as_of=result.finished_at, model=result.macro.model, body=result.macro.body, inputs=result.regime));
    for t in result.tickers {
        cov = public(run +>:Covers():+> Coverage(
            ticker=t.pick.symbol,
            sector=t.pick.sector,
            reason=COVERAGE_REASONS[t.pick.reason],
            screen_score=t.pick.score or 0.0,
            reason_note=t.pick.note,
            fetch_errors=t.fetch_errors
        ));
        for r in t.reports {
            public(cov +>:Researched():+> ResearchRecord(ticker=r.ticker, domain=r.domain, as_of=result.finished_at, model=r.model, body=r.body));
        }
    }
    return run;
}
