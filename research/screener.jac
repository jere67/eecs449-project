"""The deterministic S&P 500 screen (TDD §5): about 500 constituents to a shortlist of 15
new candidates, plus every open position and up to three Orchestrator wildcards.

`screen` is pure: the same candidates and positions always give the same shortlist, with
no model calls. `gather` collects its inputs for one trading day from the collectors.

The composite score is
    S = w1 z(mom20) + w2 z(mom60) + w3 z(rvol5) + w4 z(news3) + w5 [earnings within 5 sessions] - w6 z(vol20)
with z the cross-sectional z-score over the liquid universe. A missing feature scores 0,
the universe mean. Weights start equal (GAP-03) and the $50M liquidity floor is a proposal
(GAP-02); both are versioned in SCREEN_VERSION, and the harness tunes them before launch.
"""
import statistics;
import from datetime { date, timedelta }
import from research.alpaca { Asset, assets, daily_bars, market_calendar }
import from research.alpaca_news { article_counts }
import from research.collector { RunBudget, SourceClient, SourceError }
import from research.finnhub { earnings_calendar }
import from research.indicators { Technicals, summarize }
import from research.wikipedia { Constituent }

glob SCREEN_VERSION: str = "2026-10-08.1";

obj ScreenConfig {
    has shortlist_size: int = 15,
        per_sector: int = 3,
        min_dollar_volume: float = 50_000_000.0,
        max_wildcards: int = 3,
        earnings_sessions: int = 5,
        news_sessions: int = 3,
        weights: dict[str, float] = {
            "momentum_20": 1.0,
            "momentum_60": 1.0,
            "rvol_5": 1.0,
            "news_3": 1.0,
            "earnings_soon": 1.0,
            "vol_20": -1.0
        };
}

"""One constituent's screen inputs. `company` (the SEC CIK) joins share classes such as
GOOG and GOOGL."""
obj Candidate {
    has symbol: str,
        name: str,
        company: str,
        sector: str,
        tradable: bool,
        momentum_20: float | None,
        momentum_60: float | None,
        rvol_5: float | None,
        vol_20: float | None,
        dollar_volume_20: float | None,
        news_3: int,
        earnings_soon: bool;
}

"""A scored candidate: each weighted term of its score, for the dashboard."""
obj ScoreRow {
    has symbol: str,
        sector: str,
        score: float,
        terms: dict[str, float];
}

enum PickReason: str {
    SCORE = "score",
    OPEN_POSITION = "open_position",
    WILDCARD = "wildcard"
}

obj Pick {
    has symbol: str,
        sector: str,
        reason: PickReason,
        note: str = "",
        score: float | None = None;
}

obj Shortlist {
    has picks: list[Pick],
        scores: list[ScoreRow],
        excluded: dict[str, str],
        version: str = SCREEN_VERSION;

    def symbols -> list[str] {
        return [p.symbol for p in self.picks];
    }
}

"""A ticker the Orchestrator adds from the macro brief or breaking news, with its reason."""
obj Wildcard {
    has symbol: str,
        reason: str;
}

"""Steps 4 to 7: drop the illiquid and untradable, score the rest, take the top names with
at most `per_sector` from any sector and one share class per company, and append every
open position."""
def screen(candidates: list[Candidate], open_positions: list[str], config: ScreenConfig = ScreenConfig()) -> Shortlist {
    excluded: dict[str, str] = {};
    liquid: list[Candidate] = [];
    for c in sorted(candidates, key=lambda (c: Candidate) { c.symbol; }) {
        if not c.tradable {
            excluded[c.symbol] = "not tradable on Alpaca";
        } elif c.dollar_volume_20 is None {
            excluded[c.symbol] = "under 20 sessions of history";
        } elif c.dollar_volume_20 < config.min_dollar_volume {
            excluded[c.symbol] = f"20-day dollar volume ${c.dollar_volume_20 / 1e6:.1f}M is under ${config.min_dollar_volume / 1e6:.0f}M";
        } else {
            liquid.append(c);
        }
    }
    features: dict[str, list[float | None]] = {
        "momentum_20": [c.momentum_20 for c in liquid],
        "momentum_60": [c.momentum_60 for c in liquid],
        "rvol_5": [c.rvol_5 for c in liquid],
        "news_3": [float(c.news_3) for c in liquid],
        "vol_20": [c.vol_20 for c in liquid]
    };
    z = {name: zscores(values) for (name, values) in features.items()};
    rows: list[ScoreRow] = [];
    for (i, c) in enumerate(liquid) {
        terms = {name: config.weights[name] * z[name][i] for name in features};
        terms["earnings_soon"] = config.weights["earnings_soon"] * (1.0 if c.earnings_soon else 0.0);
        rows.append(ScoreRow(symbol=c.symbol, sector=c.sector, score=sum(terms.values()), terms=terms));
    }
    # Highest score first; equal scores fall back to the symbol, so the order is total.
    rows.sort(key=lambda (r: ScoreRow) { (-r.score, r.symbol); });
    picks: list[Pick] = [];
    per_sector: dict[str, int] = {};
    companies = {c.symbol: c.company or c.symbol for c in liquid};
    taken: dict[str, str] = {};
    for row in rows {
        if len(picks) >= config.shortlist_size {
            break;
        }
        company = companies[row.symbol];
        if company in taken {
            # Two share classes are one company's risk; research the higher-scoring one.
            excluded[row.symbol] = f"another share class of the same company, {taken[company]}, scored higher";
        } elif per_sector.get(row.sector, 0) < config.per_sector {
            taken[company] = row.symbol;
            per_sector[row.sector] = per_sector.get(row.sector, 0) + 1;
            picks.append(Pick(symbol=row.symbol, sector=row.sector, reason=PickReason.SCORE, score=row.score));
        }
    }
    chosen = {p.symbol for p in picks};
    sectors = {c.symbol: c.sector for c in candidates};
    for symbol in sorted(set(open_positions)) {
        if symbol not in chosen {
            picks.append(Pick(symbol=symbol, sector=sectors.get(symbol, ""), reason=PickReason.OPEN_POSITION, note="open position: exits are always evaluated"));
            chosen.add(symbol);
        }
    }
    return Shortlist(picks=picks, scores=rows, excluded=excluded);
}

"""Step 8: append up to `max_wildcards` Orchestrator picks not already listed, each with its
reason. Returns the wildcards refused, with why."""
def add_wildcards(shortlist: Shortlist, wildcards: list[Wildcard], config: ScreenConfig = ScreenConfig()) -> list[str] {
    refused: list[str] = [];
    added = len([p for p in shortlist.picks if p.reason == PickReason.WILDCARD]);
    listed = set(shortlist.symbols());
    for w in wildcards {
        if not w.reason.strip() {
            refused.append(f"{w.symbol}: a wildcard needs a reason");
        } elif w.symbol in listed {
            refused.append(f"{w.symbol}: already on the shortlist");
        } elif added >= config.max_wildcards {
            refused.append(f"{w.symbol}: at most {config.max_wildcards} wildcards a run");
        } else {
            shortlist.picks.append(Pick(symbol=w.symbol, sector="", reason=PickReason.WILDCARD, note=w.reason.strip()));
            listed.add(w.symbol);
            added += 1;
        }
    }
    return refused;
}

"""Cross-sectional z-scores with the population deviation; a missing value, or a feature
with no spread, scores 0."""
def zscores(values: list[float | None]) -> list[float] {
    present = [v for v in values if v is not None];
    if len(present) < 2 {
        return [0.0 for _ in values];
    }
    mean = statistics.fmean(present);
    spread = statistics.pstdev(present);
    if spread == 0 {
        return [0.0 for _ in values];
    }
    return [(v - mean) / spread if v is not None else 0.0 for v in values];
}

"""Clients for each source `gather` reads; None uses the default client."""
obj ScreenSources {
    has alpaca_data: SourceClient | None = None,
        alpaca_trading: SourceClient | None = None,
        finnhub: SourceClient | None = None;
}

"""Steps 1 to 3 and the score's inputs, for a run trading on `run_day` (ISO date): bars to
the last session before it, news over the three sessions before it, and earnings in the
five sessions from it. A failed news or earnings source becomes a gap, not a failed screen.
"""
def gather(
    run_day: str,
    members: list[Constituent],
    budget: RunBudget,
    sources: ScreenSources = ScreenSources(),
    config: ScreenConfig = ScreenConfig()
) -> tuple[list[Candidate], list[str]] {
    day = date.fromisoformat(run_day);
    sessions = [
        d.day
        for d in market_calendar((day - timedelta(days=21)).isoformat(), (day + timedelta(days=21)).isoformat(), budget, sources.alpaca_trading)
    ];
    before = [s for s in sessions if s < run_day];
    ahead = [s for s in sessions if s >= run_day][:config.earnings_sessions];
    if len(before) < config.news_sessions or not ahead {
        raise ValueError(f"the market calendar around {run_day} has too few sessions: {sessions}");
    }
    gaps: list[str] = [];
    symbols = [m.symbol for m in members];
    listed = assets(budget, sources.alpaca_trading);
    year_ago = (date.fromisoformat(before[-1]) - timedelta(days=366)).isoformat();
    (series, bar_gaps) = daily_bars(symbols, year_ago, before[-1], budget, sources.alpaca_data);
    gaps.extend(bar_gaps);
    technicals: dict[str, Technicals] = {s.symbol: summarize(s) for s in series};
    news: dict[str, int] = {};
    try {
        (news, news_gaps) = article_counts(symbols, before[-config.news_sessions], budget, sources.alpaca_data);
        gaps.extend(news_gaps);
    } except SourceError as e {
        gaps.append(f"screener: news counts are unavailable, so the news term is 0 for every name ({e})");
    }
    reporting: set[str] = set();
    try {
        (releases, earnings_gaps) = earnings_calendar(ahead[0], ahead[-1], budget, sources.finnhub);
        reporting = {r.symbol for r in releases};
        gaps.extend(earnings_gaps);
    } except SourceError as e {
        gaps.append(f"screener: the earnings calendar is unavailable, so no name gets the earnings flag ({e})");
    }
    candidates: list[Candidate] = [];
    for m in members {
        t = technicals.get(m.symbol);
        asset: Asset | None = listed.get(m.symbol);
        candidates.append(
            Candidate(
                symbol=m.symbol,
                name=m.name,
                company=m.cik,
                sector=m.sector,
                tradable=bool(asset and asset.tradable),
                momentum_20=t.momentum_20 if t else None,
                momentum_60=t.momentum_60 if t else None,
                rvol_5=t.rvol_5 if t else None,
                vol_20=t.realized_vol_20 if t else None,
                dollar_volume_20=t.dollar_volume_20 if t else None,
                news_3=news.get(m.symbol, 0),
                earnings_soon=m.symbol in reporting
            )
        );
    }
    return (candidates, gaps);
}
