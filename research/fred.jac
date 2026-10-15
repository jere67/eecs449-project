"""FRED macro series for the Macro sub-agent and the evaluation's risk-free rate (TDD §6,
§13): Treasury yields, the 3-month T-bill, the VIX close, CPI, and unemployment.

The key travels as the `api_key` query parameter, the only way FRED accepts it, so
SourceClient keeps it out of cache keys, stamped URLs, and recorded fixtures. Each series is
cited by its public page on fred.stlouisfed.org rather than the API URL, which needs a key.
VIX (CBOE) is copyrighted, so pages show only values derived from it, with FRED_ATTRIBUTION
(TDD §14, compliance).
"""
import json;
import from datetime { date, datetime, timedelta }
import from models.research { Stamped }
import from research.collector { RunBudget, SourceClient, SourceError, env_key, split_fresh }
import from research.sources { DATASETS, SOURCES }

# Required on any page that shows FRED-derived values
# (https://fred.stlouisfed.org/docs/api/terms_of_use.html).
glob FRED_ATTRIBUTION: str = "This product uses the FRED® API but is not endorsed or certified by the Federal Reserve Bank of St. Louis.";
glob SERIES_PAGE: str = "https://fred.stlouisfed.org/series/";
# FRED writes a missing observation, such as a bond-market holiday, as ".".
glob MISSING: str = ".";

"""A series the project reads, and how far back a run asks for it."""
obj SeriesInfo {
    has id: str,
        title: str,
        units: str,
        dataset: str,
        lookback_days: int;
}

# Daily series need 60 sessions for 20- and 60-day changes; monthly ones need 13 months for a
# year-over-year change.
glob FRED_SERIES: dict[str, SeriesInfo] = {
    s.id: s
    for s in [
        SeriesInfo(id="DGS2", title="2-year Treasury yield", units="percent", dataset="fred.daily", lookback_days=120),
        SeriesInfo(id="DGS10", title="10-year Treasury yield", units="percent", dataset="fred.daily", lookback_days=120),
        # The Sharpe ratio's risk-free rate (TDD §13).
        SeriesInfo(id="DTB3", title="3-month Treasury bill rate", units="percent", dataset="fred.daily", lookback_days=120),
        SeriesInfo(id="VIXCLS", title="CBOE VIX close", units="index", dataset="fred.daily", lookback_days=120),
        SeriesInfo(id="CPIAUCSL", title="Consumer price index, all urban consumers, seasonally adjusted", units="index 1982-84=100", dataset="fred.monthly", lookback_days=430),
        SeriesInfo(id="UNRATE", title="Unemployment rate, seasonally adjusted", units="percent", dataset="fred.monthly", lookback_days=430)
    ]
};

obj Observation {
    has day: str,
        value: float;
}

"""One series' observations, oldest first, without missing days, published as of the newest."""
obj FredSeries(Stamped) {
    has id: str,
        title: str,
        units: str,
        observations: list[Observation];

    """The newest value, or None for an empty series."""
    def latest -> float | None {
        return self.observations[-1].value if self.observations else None;
    }
}

def fred_client -> SourceClient {
    return SourceClient(source=SOURCES["fred"], secrets={"api_key": env_key("fred", "FRED_API_KEY")});
}

def series_url(series_id: str) -> str {
    return SERIES_PAGE + series_id;
}

"""The observations of `series_id` from `start` through `end` (ISO dates), or None when the
range has no values."""
def observations(
    series_id: str,
    start: str,
    end: str,
    budget: RunBudget,
    client: SourceClient | None = None
) -> FredSeries | None {
    info = FRED_SERIES[series_id];
    fetched = (client or fred_client()).get(
        DATASETS[info.dataset],
        "/series/observations",
        budget,
        params={
            "series_id": series_id,
            "observation_start": start,
            "observation_end": end,
            "sort_order": "asc",
            "file_type": "json"
        },
        symbol=series_id,
        day=end,
        check=_check_observations
    );
    rows: list[dict[str, str]] = json.loads(fetched.body)["observations"];
    found = [
        Observation(day=row["date"], value=float(row["value"]))
        for row in rows
        if row.get("value", MISSING) not in (MISSING, "")
    ];
    if not found {
        return None;
    }
    return FredSeries(
        id=series_id,
        title=info.title,
        units=info.units,
        observations=found,
        stamp=fetched.stamp(found[-1].day, source_url=series_url(series_id))
    );
}

"""Every series in FRED_SERIES as of `as_of` (ISO date), keeping those fresh at `now`
(default: the current time). A series that fails, is empty, or is stale becomes a gap; a
missing key is one gap for all."""
def macro_series(
    as_of: str,
    budget: RunBudget,
    client: SourceClient | None = None,
    now: datetime | None = None
) -> tuple[list[FredSeries], list[str]] {
    try {
        fred = client or fred_client();
    } except SourceError as e {
        return ([], [f"fred: no macro series, since {e}"]);
    }
    end = date.fromisoformat(as_of);
    found: list[FredSeries] = [];
    gaps: list[str] = [];
    for info in FRED_SERIES.values() {
        start = (end - timedelta(days=info.lookback_days)).isoformat();
        try {
            series = observations(info.id, start, as_of, budget, fred);
        } except SourceError as e {
            gaps.append(f"fred: {info.id} is unavailable ({e})");
            continue;
        }
        if series is None {
            gaps.append(f"fred: {info.id} has no observations from {start} to {as_of}");
            continue;
        }
        (fresh, stale) = split_fresh([series], DATASETS[info.dataset], now);
        found.extend(fresh);
        gaps.extend(stale);
    }
    return (found, gaps);
}

def _check_observations(body: str) -> str {
    try {
        parsed = json.loads(body);
    } except ValueError {
        return f"not JSON: {body[:200]}";
    }
    return "" if isinstance(parsed, dict) and isinstance(parsed.get("observations"), list) else f"no observations list in {body[:200]}";
}
