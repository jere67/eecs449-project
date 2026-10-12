"""Finnhub's free endpoints (TDD §6): company news, the earnings calendar, recommendation
trends, EPS surprises, and key metrics, for the Fundamentals and News sub-agents and the
screener's earnings flag.

The key travels in the X-Finnhub-Token header, so it never appears in a URL. The free plan
is for personal use: pages show derived results and links, not Finnhub's raw data.
"""
import json;
import from datetime { date, datetime, timedelta, timezone }
import from models.research { Stamped }
import from research.alpaca_news { Article, MAX_CONTENT_CHARS, MAX_HEADLINE_CHARS, MAX_SUMMARY_CHARS }
import from research.collector { Fetched, RunBudget, SourceClient, env_key }
import from research.sources { DATASETS, SOURCES }
import from research.text { cap, html_to_text }

# The all-company calendar silently stops at this many rows, dropping the earliest dates
# (checked 2026-10-08), so a range that fills it is split in two.
glob CALENDAR_ROW_CAP: int = 1500;

# The metrics the Fundamentals sub-agent reads, out of about 130 Finnhub returns.
glob KEY_METRICS: list[str] = [
    "marketCapitalization",
    "enterpriseValue",
    "peTTM",
    "forwardPE",
    "pegTTM",
    "psTTM",
    "pbQuarterly",
    "evEbitdaTTM",
    "epsTTM",
    "epsGrowthTTMYoy",
    "epsGrowthQuarterlyYoy",
    "revenueGrowthTTMYoy",
    "revenueGrowthQuarterlyYoy",
    "grossMarginTTM",
    "operatingMarginTTM",
    "netProfitMarginTTM",
    "roeTTM",
    "roaTTM",
    "currentRatioQuarterly",
    "totalDebt/totalEquityQuarterly",
    "netInterestCoverageTTM",
    "pfcfShareTTM",
    "payoutRatioTTM",
    "dividendYieldIndicatedAnnual",
    "beta"
];

"""A scheduled or reported earnings release. `hour` is "bmo" (before the open), "amc"
(after the close), "dmh" (during market hours), or "" when unknown."""
obj EarningsDate(Stamped) {
    has symbol: str,
        day: str,
        hour: str,
        quarter: int,
        year: int,
        eps_estimate: float | None,
        eps_actual: float | None,
        revenue_estimate: float | None,
        revenue_actual: float | None;
}

"""Analyst ratings counted for one month, `period` being its first day."""
obj RecommendationTrend(Stamped) {
    has symbol: str,
        period: str,
        strong_buy: int,
        buy: int,
        hold: int,
        sell: int,
        strong_sell: int;
}

"""Reported EPS against the consensus for the quarter ending on `period`."""
obj EpsSurprise(Stamped) {
    has symbol: str,
        period: str,
        quarter: int,
        year: int,
        actual: float | None,
        estimate: float | None,
        surprise: float | None,
        surprise_percent: float | None;
}

"""The KEY_METRICS Finnhub has for a symbol; ratios and growth are in percent."""
obj KeyMetrics(Stamped) {
    has symbol: str,
        values: dict[str, float];
}

def finnhub_client -> SourceClient {
    return SourceClient(
        source=SOURCES["finnhub"],
        headers={"X-Finnhub-Token": env_key("finnhub", "FINNHUB_API_KEY")}
    );
}

"""The newest `limit` articles about `symbol` from `start` through `end` (ISO dates), as
capped plain text. Finnhub has headlines and summaries but no article bodies."""
def company_news(
    symbol: str,
    start: str,
    end: str,
    budget: RunBudget,
    client: SourceClient | None = None,
    limit: int = 20
) -> list[Article] {
    fetched = _get(client, "finnhub.news", "/company-news", budget, {"symbol": symbol, "from": start, "to": end}, symbol, _check_list);
    rows: list[dict[str, str | int | float | None]] = sorted(
        json.loads(fetched.body), key=lambda (r: dict[str, str | int | float | None]) { int(r.get("datetime") or 0); }, reverse=True
    );
    found: list[Article] = [];
    for row in rows[:limit] {
        published = datetime.fromtimestamp(int(row["datetime"]), timezone.utc).isoformat();
        found.append(
            Article(
                id=int(row.get("id") or 0),
                headline=cap(html_to_text(str(row.get("headline") or "")), MAX_HEADLINE_CHARS),
                summary=cap(html_to_text(str(row.get("summary") or "")), MAX_SUMMARY_CHARS),
                content=cap("", MAX_CONTENT_CHARS),
                author="",
                source=str(row.get("source") or ""),
                url=str(row.get("url") or ""),
                symbols=[s for s in str(row.get("related") or symbol).split(",") if s],
                created_at=published,
                updated_at=published,
                stamp=fetched.stamp(published, source_url=str(row.get("url") or "") or fetched.source_url)
            )
        );
    }
    return found;
}

"""Every earnings release Finnhub lists from `start` through `end` (ISO dates), for all
companies, and a gap for any single day that still fills the row cap."""
def earnings_calendar(
    start: str,
    end: str,
    budget: RunBudget,
    client: SourceClient | None = None
) -> tuple[list[EarningsDate], list[str]] {
    fetched = _get(client, "finnhub.earnings_calendar", "/calendar/earnings", budget, {"from": start, "to": end}, "", _check_calendar);
    rows = json.loads(fetched.body)["earningsCalendar"] or [];
    if len(rows) >= CALENDAR_ROW_CAP {
        if start == end {
            return (
                _releases(rows, fetched),
                [f"finnhub.earnings_calendar: {start} has {len(rows)} or more releases, so some may be missing"]
            );
        }
        (first, last) = (date.fromisoformat(start), date.fromisoformat(end));
        middle = first + (last - first) / 2;
        (early, early_gaps) = earnings_calendar(start, middle.isoformat(), budget, client);
        (late, late_gaps) = earnings_calendar((middle + timedelta(days=1)).isoformat(), end, budget, client);
        return (early + late, early_gaps + late_gaps);
    }
    return (_releases(rows, fetched), []);
}

"""`releases` without Finnhub's occasional repeated rows: one per symbol and day."""
def unique_releases(releases: list[EarningsDate]) -> list[EarningsDate] {
    seen: set[tuple[str, str]] = set();
    kept: list[EarningsDate] = [];
    for release in releases {
        if (release.symbol, release.day) not in seen {
            seen.add((release.symbol, release.day));
            kept.append(release);
        }
    }
    return kept;
}

"""Monthly analyst rating counts for `symbol`, newest first."""
def recommendation_trends(symbol: str, budget: RunBudget, client: SourceClient | None = None) -> list[RecommendationTrend] {
    fetched = _get(client, "finnhub.recommendations", "/stock/recommendation", budget, {"symbol": symbol}, symbol, _check_list);
    trends = [
        RecommendationTrend(
            symbol=symbol,
            period=str(row["period"]),
            strong_buy=int(row.get("strongBuy") or 0),
            buy=int(row.get("buy") or 0),
            hold=int(row.get("hold") or 0),
            sell=int(row.get("sell") or 0),
            strong_sell=int(row.get("strongSell") or 0),
            stamp=fetched.stamp(str(row["period"]))
        )
        for row in json.loads(fetched.body)
    ];
    return sorted(trends, key=lambda (t: RecommendationTrend) { t.period; }, reverse=True);
}

"""EPS against the consensus for the last four reported quarters, newest first."""
def eps_surprises(symbol: str, budget: RunBudget, client: SourceClient | None = None) -> list[EpsSurprise] {
    fetched = _get(client, "finnhub.eps_surprises", "/stock/earnings", budget, {"symbol": symbol}, symbol, _check_list);
    surprises = [
        EpsSurprise(
            symbol=symbol,
            period=str(row["period"]),
            quarter=int(row.get("quarter") or 0),
            year=int(row.get("year") or 0),
            actual=_number(row.get("actual")),
            estimate=_number(row.get("estimate")),
            surprise=_number(row.get("surprise")),
            surprise_percent=_number(row.get("surprisePercent")),
            stamp=fetched.stamp(str(row["period"]))
        )
        for row in json.loads(fetched.body)
    ];
    return sorted(surprises, key=lambda (s: EpsSurprise) { s.period; }, reverse=True);
}

"""The KEY_METRICS for `symbol`, or None when Finnhub has none of them."""
def key_metrics(symbol: str, budget: RunBudget, client: SourceClient | None = None) -> KeyMetrics | None {
    fetched = _get(client, "finnhub.metrics", "/stock/metric", budget, {"symbol": symbol, "metric": "all"}, symbol, _check_metrics);
    reported = json.loads(fetched.body)["metric"] or {};
    values: dict[str, float] = {};
    for name in KEY_METRICS {
        value = _number(reported.get(name));
        if value is not None {
            values[name] = value;
        }
    }
    if not values {
        return None;
    }
    return KeyMetrics(symbol=symbol, values=values, stamp=fetched.stamp(fetched.fetched_at));
}

def _get(
    client: SourceClient | None,
    dataset: str,
    path: str,
    budget: RunBudget,
    params: dict[str, str | int | float],
    symbol: str,
    check: Callable[[str], str]
) -> Fetched {
    return (client or finnhub_client()).get(DATASETS[dataset], path, budget, params=params, symbol=symbol, check=check);
}

def _releases(rows: list[dict[str, str | int | float | None]], fetched: Fetched) -> list[EarningsDate] {
    return unique_releases([
        EarningsDate(
            symbol=str(row["symbol"]),
            day=str(row["date"]),
            hour=str(row.get("hour") or ""),
            quarter=int(row.get("quarter") or 0),
            year=int(row.get("year") or 0),
            eps_estimate=_number(row.get("epsEstimate")),
            eps_actual=_number(row.get("epsActual")),
            revenue_estimate=_number(row.get("revenueEstimate")),
            revenue_actual=_number(row.get("revenueActual")),
            stamp=fetched.stamp(fetched.fetched_at)
        )
        for row in rows
    ]);
}

def _number(value: str | int | float | None) -> float | None {
    if value is None or isinstance(value, bool) {
        return None;
    }
    try {
        return float(value);
    } except ValueError {
        return None;
    }
}

def _parse(body: str) -> object {
    try {
        return json.loads(body);
    } except ValueError {
        return None;
    }
}

def _check_list(body: str) -> str {
    return "" if isinstance(_parse(body), list) else f"expected a list: {body[:200]}";
}

def _check_calendar(body: str) -> str {
    parsed = _parse(body);
    return "" if isinstance(parsed, dict) and "earningsCalendar" in parsed else f"no earningsCalendar in {body[:200]}";
}

def _check_metrics(body: str) -> str {
    parsed = _parse(body);
    return "" if isinstance(parsed, dict) and "metric" in parsed else f"no metric in {body[:200]}";
}
