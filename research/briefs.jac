"""Compact, sourced inputs for the research sub-agents (TDD §3 rules 11 and 12, §6, §14).

A Brief is what one sub-agent reads: numbered sources, each with the exact URL and publish
time the agent must copy into its evidence, and plain-language figures computed in code.
Agents never see raw bars or whole filings, and never do date math: every "sessions until"
or "days ago" is computed here. Article and filing text keeps its untrusted-data delimiters.

Builders are pure: they take collector outputs and return a Brief, so they are tested
without a network, and the agent layer checks every citation against `Brief.published_by_url`.
"""
import from models.agents { Domain }
import from research.alpaca_news { Article }
import from models.research { RegimeInputs }
import from research.finnhub { EarningsDate, EpsSurprise, KeyMetrics, RecommendationTrend }
import from research.indicators { BOND_BENCHMARKS, BOND_ETFS, SECTOR_ETFS, Technicals }
import from research.sec { EarningsRelease, Filing, Fundamentals, InsiderTrade, ReportedValue, TRANSACTION_CODES }
import from research.text { cap, untrusted_block }

# About 6,000 tokens: room for every figure and eight capped articles.
glob MAX_BRIEF_CHARS: int = 24000;
glob MAX_ARTICLES: int = 8;
glob MAX_ARTICLE_CHARS: int = 1200;
glob MAX_EVENTS: int = 5;
glob MAX_INSIDER_TRADES: int = 5;

"""One numbered source in a brief."""
obj BriefItem {
    has label: str,
        source_url: str,
        published: str,
        text: str;
}

"""Everything one research sub-agent reads about one ticker (or the market, for Macro)."""
obj Brief {
    has ticker: str,
        domain: Domain,
        as_of: str;
    has items: list[BriefItem] = [],
        gaps: list[str] = [];

    """Add a source; empty text is skipped. Add the most important sources first, since the
    length cap drops the last ones."""
    def add(label: str, source_url: str, published: str, text: str) {
        if text.strip() and source_url {
            self.items.append(BriefItem(label=label, source_url=source_url, published=published, text=text.strip()));
        }
    }

    """The sources that fit in MAX_BRIEF_CHARS, in order."""
    def kept -> list[BriefItem] {
        kept: list[BriefItem] = [];
        used = 0;
        for item in self.items {
            size = len(item.label) + len(item.source_url) + len(item.published) + len(item.text) + 60;
            if used + size > MAX_BRIEF_CHARS {
                break;
            }
            kept.append(item);
            used += size;
        }
        return kept;
    }

    """The numbered sources as the agent reads them."""
    def render -> str {
        blocks = [
            f"[{i + 1}] {item.label}\nsource_url: {item.source_url}\npublished: {item.published}\n{item.text}"
            for (i, item) in enumerate(self.kept())
        ];
        return "\n\n".join(blocks) if blocks else "(no sources)";
    }

    """Each kept source's URL and publish time: the only citations a report may make."""
    def published_by_url -> dict[str, str] {
        return {item.source_url: item.published for item in self.kept()};
    }

    """Gaps found while building, plus a note for sources the length cap dropped."""
    def all_gaps -> list[str] {
        dropped = len(self.items) - len(self.kept());
        return self.gaps + ([f"{dropped} lower-priority sources were left out to fit the length cap"] if dropped else []);
    }
}

"""What the collectors found for the Market and Technical sub-agent. `sector_etf` is the
sector's SPDR fund."""
obj MarketInputs {
    has stock: Technicals | None = None,
        spy: Technicals | None = None,
        sector: Technicals | None = None,
        sector_etf: str = "",
        gaps: list[str] = [];
}

"""What the collectors found for the Fundamentals and Filings sub-agent. `trades` is None
when Form 4 data could not be read, and empty when none were filed since `insider_since`."""
obj FundamentalsInputs {
    has sec: Fundamentals | None = None,
        metrics: KeyMetrics | None = None,
        trends: list[RecommendationTrend] = [],
        surprises: list[EpsSurprise] = [],
        trades: list[InsiderTrade] | None = None,
        insider_since: str = "",
        gaps: list[str] = [];
}

"""What the collectors found for the News and Events sub-agent. `sessions_until` counts
trading sessions from the run date to `next_earnings`."""
obj NewsInputs {
    has next_earnings: EarningsDate | None = None,
        sessions_until: int | None = None,
        events: list[Filing] = [],
        release: EarningsRelease | None = None,
        articles: list[Article] = [],
        gaps: list[str] = [];
}

"""The Market and Technical sub-agent's brief."""
def market_brief(ticker: str, as_of: str, inputs: MarketInputs) -> Brief {
    brief = Brief(ticker=ticker, domain=Domain.MARKET, as_of=as_of, gaps=list(inputs.gaps));
    (stock, spy, sector, sector_etf) = (inputs.stock, inputs.spy, inputs.sector, inputs.sector_etf);
    if stock is None {
        brief.gaps.append(f"market: no daily bars for {ticker}, so no indicators");
    } else {
        brief.add(f"{ticker} technical indicators from daily bars (computed in code)", stock.stamp.source_url, stock.stamp.published_at, technicals_text(stock, sector_etf));
    }
    for (name, benchmark) in [("SPY (S&P 500 fund)", spy), (f"{sector_etf} (sector fund)" if sector_etf else "sector fund", sector)] {
        if benchmark is None {
            brief.gaps.append(f"market: no bars for {name}, so no relative strength against it");
        } else {
            brief.add(f"{name} trend, for context", benchmark.stamp.source_url, benchmark.stamp.published_at, benchmark_text(benchmark));
        }
    }
    return brief;
}

"""The Fundamentals and Filings sub-agent's brief."""
def fundamentals_brief(ticker: str, as_of: str, inputs: FundamentalsInputs) -> Brief {
    brief = Brief(ticker=ticker, domain=Domain.FUNDAMENTALS, as_of=as_of, gaps=list(inputs.gaps));
    (sec, metrics, trends, surprises) = (inputs.sec, inputs.metrics, inputs.trends, inputs.surprises);
    if sec is None {
        brief.gaps.append(f"fundamentals: no SEC XBRL figures for {ticker}");
    } else {
        # One source per filing, so each figure cites the filing that reported it.
        by_filing: dict[str, list[ReportedValue]] = {};
        for v in sec.values {
            by_filing.setdefault(v.source_url, []).append(v);
        }
        for (url, values) in sorted(by_filing.items(), key=lambda (kv: tuple[str, list[ReportedValue]]) { max(v.filed for v in kv[1]); }, reverse=True) {
            filed = max(v.filed for v in values);
            brief.add(f"{ticker} financial statements reported to the SEC (filed {filed})", url, filed, "\n".join(reported_line(v) for v in values));
        }
    }
    if metrics is None {
        brief.gaps.append(f"fundamentals: no Finnhub key metrics for {ticker}");
    } else {
        brief.add(f"{ticker} valuation and quality metrics (Finnhub)", metrics.stamp.source_url, metrics.stamp.published_at, metrics_text(metrics));
    }
    if surprises {
        brief.add(f"{ticker} reported EPS against the consensus, last {len(surprises)} quarters (Finnhub)", surprises[0].stamp.source_url, surprises[0].stamp.published_at, "\n".join(surprise_line(s) for s in surprises));
    } else {
        brief.gaps.append(f"fundamentals: no EPS surprise history for {ticker}");
    }
    if trends {
        brief.add(f"{ticker} analyst ratings by month (Finnhub)", trends[0].stamp.source_url, trends[0].stamp.published_at, "\n".join(trend_line(t) for t in trends[:4]));
    } else {
        brief.gaps.append(f"fundamentals: no analyst rating counts for {ticker}");
    }
    if inputs.trades is None {
        brief.gaps.append(f"fundamentals: insider transactions for {ticker} are unavailable");
    } else {
        add_insider_sources(brief, inputs.trades, inputs.insider_since);
    }
    return brief;
}

"""The News and Events sub-agent's brief."""
def news_brief(ticker: str, as_of: str, inputs: NewsInputs) -> Brief {
    brief = Brief(ticker=ticker, domain=Domain.NEWS, as_of=as_of, gaps=list(inputs.gaps));
    if inputs.next_earnings is not None {
        e = inputs.next_earnings;
        brief.add(f"{ticker} next scheduled earnings release (Finnhub calendar)", e.stamp.source_url, e.stamp.published_at, earnings_date_text(e, inputs.sessions_until));
    }
    for filing in inputs.events[:MAX_EVENTS] {
        brief.add(f"{ticker} 8-K current report filed {filing.filed}", filing.stamp.source_url, filing.filed, f"Form {filing.form} filed {filing.filed} reporting: {'; '.join(filing.item_names()) or 'no items listed'}.");
    }
    release = inputs.release;
    if release is not None {
        brief.add(f"{ticker} earnings press release (8-K exhibit 99), filed {release.filed}", release.exhibit_url, release.filed, release.as_untrusted());
    }
    chosen = pick_articles(inputs.articles, MAX_ARTICLES);
    if not chosen {
        brief.gaps.append(f"news: no recent articles about {ticker}");
    }
    for a in chosen {
        brief.add(f"News article from {a.source or 'unknown source'}, {a.created_at[:16].replace('T', ' ')} UTC", a.stamp.source_url, a.created_at, article_block(a));
    }
    return brief;
}

"""The newest `limit` articles, without repeats of one story across sources."""
def pick_articles(articles: list[Article], limit: int) -> list[Article] {
    seen: set[str] = set();
    picked: list[Article] = [];
    for a in sorted(articles, key=lambda (a: Article) { a.created_at; }, reverse=True) {
        key = " ".join(a.headline.lower().split());
        if not a.stamp.source_url or a.stamp.source_url in seen or key in seen {
            continue;
        }
        seen.update({a.stamp.source_url, key});
        picked.append(a);
        if len(picked) >= limit {
            break;
        }
    }
    return picked;
}

"""An article as capped untrusted data: headline, summary, then body text."""
def article_block(a: Article) -> str {
    text = "\n\n".join(part for part in [a.headline, a.summary, a.content] if part);
    return untrusted_block("news article", cap(text, MAX_ARTICLE_CHARS), {"source": a.source, "published": a.created_at});
}

"""Insider trades as one summary source and a source for each of the largest open-market
trades, each citing its own Form 4."""
def add_insider_sources(brief: Brief, trades: list[InsiderTrade], since: str) {
    if not trades {
        brief.add(f"{brief.ticker} insider transactions since {since} (SEC Form 4)", f"https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK={brief.ticker}&type=4", brief.as_of, f"No Form 4 transactions in common stock were filed from {since} to {brief.as_of}.");
        return;
    }
    newest = max(trades, key=lambda (t: InsiderTrade) { t.filed; });
    buys = [t for t in trades if t.code == "P"];
    sells = [t for t in trades if t.code == "S"];
    lines = [
        f"Form 4 transactions in common stock filed since {since}: {len(trades)}, by {len({t.insider for t in trades})} insiders.",
        _side("Open-market purchases", buys),
        _side("Open-market sales", sells)
    ];
    others: dict[str, int] = {};
    for t in trades {
        if t.code not in ("P", "S") {
            name = TRANSACTION_CODES.get(t.code, f"code {t.code}");
            others[name] = others.get(name, 0) + 1;
        }
    }
    if others {
        lines.append("Other transactions (mostly compensation): " + ", ".join(f"{name} x{n}" for (name, n) in sorted(others.items())) + ".");
    }
    planned = len([t for t in buys + sells if t.planned]);
    if buys or sells {
        lines.append(f"{planned} of {len(buys) + len(sells)} open-market trades were filed as made under a Rule 10b5-1 trading plan, which schedules them in advance.");
    }
    lags = sorted(t.filing_lag_days for t in trades);
    lines.append(f"Filing lag from trade to filing: median {lags[len(lags) // 2]} days, longest {lags[-1]} days.");
    brief.add(f"{brief.ticker} insider activity summary since {since} (SEC Form 4)", newest.stamp.source_url, newest.filed, "\n".join(lines));
    largest = sorted(buys + sells, key=lambda (t: InsiderTrade) { t.value() or 0.0; }, reverse=True)[:MAX_INSIDER_TRADES];
    for t in largest {
        brief.add(f"{brief.ticker} Form 4 filed {t.filed}", t.stamp.source_url, t.filed, insider_line(t));
    }
}

def _side(label: str, trades: list[InsiderTrade]) -> str {
    if not trades {
        return f"{label}: none.";
    }
    value = sum(t.value() or 0.0 for t in trades);
    shares = sum(t.shares for t in trades);
    return f"{label}: {len(trades)} trades by {len({t.insider for t in trades})} insiders, {shares:,.0f} shares, about {usd(value)}.";
}

def insider_line(t: InsiderTrade) -> str {
    price = f" at ${t.price:,.2f}" if t.price else "";
    after = f"; holds {t.shares_after:,.0f} shares after" if t.shares_after is not None else "";
    plan = " under a Rule 10b5-1 plan" if t.planned else "";
    return f"{t.insider} ({t.role}): {TRANSACTION_CODES.get(t.code, t.code)} of {t.shares:,.0f} shares{price} on {t.day}{plan}{after}; filed {t.filing_lag_days} days later.";
}

"""Every indicator in plain words, for the Market sub-agent."""
def technicals_text(t: Technicals, sector_etf: str = "") -> str {
    def vs(level: float | None) -> str {
        return f"{usd(level)} (close is {change(t.close / level - 1.0)} from it)" if level else "n/a";
    }
    lines = [
        f"Close on {t.as_of}: {usd(t.close)}; {t.bars} daily bars of history.",
        f"Moving averages: 20-day {vs(t.sma_20)}; 50-day {vs(t.sma_50)}; 200-day {vs(t.sma_200)}.",
        f"RSI(14): {number(t.rsi_14)} (above 70 is often read as overbought, below 30 as oversold).",
        f"MACD(12, 26, 9): line {number(t.macd, 2)}, signal {number(t.macd_signal, 2)}, histogram {number(t.macd_hist, 2)}.",
        f"Bollinger band width (20-day, 2 deviations): {pct(t.bollinger_width)} of the middle band.",
        f"Average true range (14-day): {usd(t.atr_14)}, or {pct(t.atr_pct)} of the close.",
        f"Position in the 52-week range: {pct(t.range_52w_position, 0)} (0% is the low, 100% the high).",
        f"Momentum: 20-day {change(t.momentum_20)}, 60-day {change(t.momentum_60)}.",
        f"Relative volume (5-day average over 60-day average): {number(t.rvol_5, 2)}x.",
        f"Realized volatility (20-day, annualized): {pct(t.realized_vol_20)}.",
        f"Average daily dollar volume (20-day): {usd(t.dollar_volume_20)}.",
        f"Relative strength against SPY: 20-day {change(t.rs_spy_20)}, 60-day {change(t.rs_spy_60)}."
    ];
    if sector_etf {
        lines.append(f"Relative strength against its sector fund {sector_etf}: 20-day {change(t.rs_sector_20)}, 60-day {change(t.rs_sector_60)}.");
    }
    return "\n".join(lines);
}

"""A benchmark's trend in a few figures."""
def benchmark_text(t: Technicals) -> str {
    above = "above" if t.sma_200 and t.close > t.sma_200 else "below" if t.sma_200 else "n/a against";
    return "\n".join([
        f"Close on {t.as_of}: {usd(t.close)}, {above} its 200-day average {usd(t.sma_200)}.",
        f"Momentum: 20-day {change(t.momentum_20)}, 60-day {change(t.momentum_60)}.",
        f"Realized volatility (20-day, annualized): {pct(t.realized_vol_20)}."
    ]);
}

# Finnhub metric names in words, and whether each is a percent already (TDD §6).
glob METRIC_LABELS: dict[str, tuple[str, str]] = {
    "marketCapitalization": ("Market capitalization", "musd"),
    "enterpriseValue": ("Enterprise value", "musd"),
    "peTTM": ("Price to earnings (trailing 12 months)", "x"),
    "forwardPE": ("Price to earnings (forward)", "x"),
    "pegTTM": ("PEG ratio (trailing)", "x"),
    "psTTM": ("Price to sales (trailing)", "x"),
    "pbQuarterly": ("Price to book", "x"),
    "evEbitdaTTM": ("Enterprise value to EBITDA (trailing)", "x"),
    "epsTTM": ("EPS (trailing 12 months)", "usd"),
    "epsGrowthTTMYoy": ("EPS growth, trailing 12 months year over year", "pct"),
    "epsGrowthQuarterlyYoy": ("EPS growth, latest quarter year over year", "pct"),
    "revenueGrowthTTMYoy": ("Revenue growth, trailing 12 months year over year", "pct"),
    "revenueGrowthQuarterlyYoy": ("Revenue growth, latest quarter year over year", "pct"),
    "grossMarginTTM": ("Gross margin (trailing)", "pct"),
    "operatingMarginTTM": ("Operating margin (trailing)", "pct"),
    "netProfitMarginTTM": ("Net margin (trailing)", "pct"),
    "roeTTM": ("Return on equity (trailing)", "pct"),
    "roaTTM": ("Return on assets (trailing)", "pct"),
    "currentRatioQuarterly": ("Current ratio", "x"),
    "totalDebt/totalEquityQuarterly": ("Total debt to equity", "x"),
    "netInterestCoverageTTM": ("Interest coverage (trailing)", "x"),
    "pfcfShareTTM": ("Price to free cash flow (trailing)", "x"),
    "payoutRatioTTM": ("Dividend payout ratio (trailing)", "pct"),
    "dividendYieldIndicatedAnnual": ("Dividend yield (indicated)", "pct"),
    "beta": ("Beta against the market", "x")
};

def metrics_text(m: KeyMetrics) -> str {
    lines: list[str] = [];
    for (name, (label, unit)) in METRIC_LABELS.items() {
        if name not in m.values {
            continue;
        }
        value = m.values[name];
        shown = usd(value * 1e6) if unit == "musd" else usd(value) if unit == "usd" else f"{value:.1f}%" if unit == "pct" else f"{value:.2f}x";
        lines.append(f"{label}: {shown}.");
    }
    return "\n".join(lines);
}

# SEC figure names (research/sec.jac) in words, and what each suffix means.
glob FIGURE_LABELS: dict[str, str] = {
    "revenue": "Revenue",
    "gross_profit": "Gross profit",
    "operating_income": "Operating income",
    "net_income": "Net income",
    "operating_cash_flow": "Operating cash flow",
    "capital_expenditure": "Capital expenditure",
    "free_cash_flow": "Free cash flow",
    "eps_diluted": "Diluted EPS",
    "gross_margin": "Gross margin",
    "operating_margin": "Operating margin",
    "net_margin": "Net margin",
    "total_assets": "Total assets",
    "total_liabilities": "Total liabilities",
    "stockholders_equity": "Stockholders' equity",
    "cash": "Cash and equivalents",
    "long_term_debt": "Long-term debt",
    "long_term_debt_to_equity": "Long-term debt to equity",
    "shares_outstanding": "Shares outstanding"
};

glob FIGURE_SUFFIXES: list[tuple[str, str]] = [
    ("_quarter_prior_year", ", same quarter a year earlier"),
    ("_growth_yoy", " growth, year over year"),
    ("_quarter", ", latest quarter"),
    ("_ttm", ", trailing 12 months")
];

"""One SEC figure in words, such as "Revenue, latest quarter: $109.4B (quarter ...)"."""
def reported_line(v: ReportedValue) -> str {
    (base, suffix) = (v.name, "");
    for (ending, words) in FIGURE_SUFFIXES {
        if v.name.endswith(ending) {
            (base, suffix) = (v.name[:-len(ending)], words);
            break;
        }
    }
    label = FIGURE_LABELS.get(base, base.replace("_", " ").capitalize()) + suffix;
    if v.unit == "fraction" {
        shown = change(v.value) if "growth" in v.name else pct(v.value);
    } elif v.unit == "USD" {
        shown = usd(v.value);
    } elif v.unit == "USD/share" {
        shown = f"${v.value:,.2f} per share";
    } elif v.unit == "shares" {
        shown = f"{v.value:,.0f} shares";
    } else {
        shown = f"{v.value:.2f}";
    }
    return f"{label}: {shown} ({v.period}).";
}

def surprise_line(s: EpsSurprise) -> str {
    if s.actual is None or s.estimate is None {
        return f"Quarter ending {s.period}: not reported.";
    }
    beat = "beat" if s.actual > s.estimate else "missed" if s.actual < s.estimate else "matched";
    return f"Quarter ending {s.period}: EPS ${s.actual:.2f} {beat} the ${s.estimate:.2f} estimate ({number(s.surprise_percent, 1)}% surprise).";
}

def trend_line(t: RecommendationTrend) -> str {
    total = t.strong_buy + t.buy + t.hold + t.sell + t.strong_sell;
    return f"{t.period[:7]}: {t.strong_buy} strong buy, {t.buy} buy, {t.hold} hold, {t.sell} sell, {t.strong_sell} strong sell ({total} analysts).";
}

def earnings_date_text(e: EarningsDate, sessions_until: int | None) -> str {
    when = {"bmo": "before the open", "amc": "after the close", "dmh": "during market hours"}.get(e.hour, "time not announced");
    distance = f"{sessions_until} trading sessions after the run date" if sessions_until is not None else "an unknown number of sessions away";
    parts = [f"Fiscal Q{e.quarter} {e.year} results are scheduled for {e.day}, {when}: {distance}."];
    if e.eps_estimate is not None {
        parts.append(f"Consensus EPS estimate: ${e.eps_estimate:.2f}.");
    }
    if e.revenue_estimate is not None {
        parts.append(f"Consensus revenue estimate: {usd(e.revenue_estimate)}.");
    }
    return " ".join(parts);
}

"""What the collectors found for the Macro sub-agent: SPY, then each Treasury fund and each
sector fund by ticker. Sector funds carry relative strength against SPY, and a Treasury fund
in BOND_BENCHMARKS carries it against its benchmark fund in `rs_sector_*`."""
obj MacroInputs {
    has spy: Technicals | None = None,
        bonds: dict[str, Technicals] = {},
        sectors: dict[str, Technicals] = {},
        gaps: list[str] = [];
}

"""The regime figures the risk gate reads, computed in code."""
def regime_inputs(inputs: MacroInputs) -> RegimeInputs {
    spy = inputs.spy;
    return RegimeInputs(
        spy_close=spy.close if spy else None,
        spy_sma_200=spy.sma_200 if spy else None,
        spy_vol_20=spy.realized_vol_20 if spy else None,
        spy_as_of=spy.as_of if spy else ""
    );
}

"""The Macro sub-agent's brief: once per run, shared by every ticker. Market-wide risk comes
first, then rates and inflation expectations from Treasury funds, then sector rotation."""
def macro_brief(as_of: str, inputs: MacroInputs) -> Brief {
    brief = Brief(ticker="MARKET", domain=Domain.MACRO, as_of=as_of, gaps=list(inputs.gaps));
    if inputs.spy is None {
        brief.gaps.append("macro: no SPY bars, so no market trend or regime check");
    } else {
        brief.add("SPY (S&P 500 fund) trend", inputs.spy.stamp.source_url, inputs.spy.stamp.published_at, benchmark_text(inputs.spy));
    }
    for (etf, name) in BOND_ETFS.items() {
        if etf in inputs.bonds {
            t = inputs.bonds[etf];
            brief.add(f"{etf} ({name})", t.stamp.source_url, t.stamp.published_at, bond_text(t));
        }
    }
    missing_bonds = [etf for etf in BOND_ETFS if etf not in inputs.bonds];
    if missing_bonds {
        brief.gaps.append(f"macro: no bars for Treasury funds {', '.join(missing_bonds)}");
    }
    ranked = sorted(inputs.sectors.items(), key=lambda (kv: tuple[str, Technicals]) { kv[1].rs_spy_60 if kv[1].rs_spy_60 is not None else -9.0; }, reverse=True);
    sectors = {etf: name for (name, etf) in SECTOR_ETFS.items()};
    for (rank, (etf, t)) in enumerate(ranked) {
        brief.add(
            f"{etf} ({sectors.get(etf, 'sector')} sector fund)",
            t.stamp.source_url,
            t.stamp.published_at,
            f"Ranks {rank + 1} of {len(ranked)} sector funds by 60-day strength against SPY.\nRelative strength against SPY: 20-day {change(t.rs_spy_20)}, 60-day {change(t.rs_spy_60)}.\nMomentum: 20-day {change(t.momentum_20)}, 60-day {change(t.momentum_60)}."
        );
    }
    missing = sorted(set(SECTOR_ETFS.values()) - set(inputs.sectors));
    if missing {
        brief.gaps.append(f"macro: no bars for sector funds {', '.join(missing)}");
    }
    return brief;
}

"""A Treasury fund's trend in words. Bond prices move against yields, so the text says which
way the fund's returns point for rates; the returns include reinvested interest."""
def bond_text(t: Technicals) -> str {
    lines = [
        f"Close on {t.as_of}: {usd(t.close)}.",
        f"Return: 20-day {change(t.momentum_20)}, 60-day {change(t.momentum_60)} (a falling fund means its yields rose).",
        f"Realized volatility (20-day, annualized): {pct(t.realized_vol_20)}."
    ];
    if t.symbol in BOND_BENCHMARKS {
        lines.append(f"Relative strength against {BOND_BENCHMARKS[t.symbol]}, of similar maturity: 20-day {change(t.rs_sector_20)}, 60-day {change(t.rs_sector_60)} (inflation-protected Treasuries beating ordinary ones point to rising inflation expectations).");
    }
    return "\n".join(lines);
}

"""Dollars at a readable scale: $109.4B, $12.3M, $331.44."""
def usd(value: float | None) -> str {
    if value is None {
        return "n/a";
    }
    sign = "-" if value < 0 else "";
    size = abs(value);
    for (scale, suffix) in [(1e12, "T"), (1e9, "B"), (1e6, "M")] {
        if size >= scale {
            return f"{sign}${size / scale:,.1f}{suffix}";
        }
    }
    return f"{sign}${size:,.2f}";
}

"""A fraction as a percent level: 0.123 is "12.3%"."""
def pct(value: float | None, digits: int = 1) -> str {
    return "n/a" if value is None else f"{value * 100:.{digits}f}%";
}

"""A fraction as a signed change: 0.042 is "+4.2%"."""
def change(value: float | None) -> str {
    return "n/a" if value is None else f"{value * 100:+.1f}%";
}

def number(value: float | None, digits: int = 1) -> str {
    return "n/a" if value is None else f"{value:.{digits}f}";
}
