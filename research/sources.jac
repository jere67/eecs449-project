"""Versioned limits, call budgets, cache lifetimes, and freshness rules for every data source
(TDD §6, collector rules; GAP-15 in the requirements).

Bump SOURCES_VERSION with any change here, so a run's results can be tied to the rules that
produced them. The freshness limits are proposals until the Research exit run (#27) checks
them against each provider's real update cadence.

Every base URL can be overridden through its environment variable, which is how tests
replay recorded fixtures from a local server instead of calling the provider.
"""

glob SOURCES_VERSION: str = "2026-10-08.1";

glob HOUR: float = 1.0;
glob DAY: float = 24.0;

"""One provider host and how hard we may call it."""
obj Source {
    has name: str,
        base_url: str,
        base_url_env: str,
        per_minute: float,
        burst: int,
        run_budget: int;
    # Sources on one provider-wide limit share a rate limiter.
    has limit_group: str = "",
        daily_limit: int | None = None;

    def postinit {
        if not self.limit_group {
            self.limit_group = self.name;
        }
        # A run may use at most half a daily allowance, so on-demand reports never exhaust it.
        if self.daily_limit is not None and self.run_budget * 2 > self.daily_limit {
            raise ValueError(
                f"{self.name}: run budget {self.run_budget} is over half the daily limit {self.daily_limit}"
            );
        }
    }
}

"""One kind of data from a source, with its cache lifetime and freshness limit."""
obj Dataset {
    has name: str,
        source: str,
        max_age_hours: float;
    # None caches forever: filings and closed bars never change.
    has cache_ttl_hours: float | None = None;
}

# No current source has a daily cap, only per-minute ones, so each run budget is a guard
# against a runaway loop, sized from the standard run (TDD §12: 20 tickers, S&P 500 screen).
glob SOURCES: dict[str, Source] = {
    s.name: s
    for s in [
        # Basic plan: 200 historical calls a minute (TDD §6).
        Source(
            name="alpaca_data",
            base_url="https://data.alpaca.markets",
            base_url_env="ALPACA_DATA_URL",
            per_minute=180,
            burst=10,
            run_budget=500
        ),
        Source(
            name="alpaca_trading",
            base_url="https://paper-api.alpaca.markets",
            base_url_env="ALPACA_BASE_URL",
            per_minute=180,
            burst=10,
            run_budget=50
        ),
        # SEC fair access: under 10 requests a second across every sec.gov host (TDD §14).
        Source(
            name="sec_data",
            base_url="https://data.sec.gov",
            base_url_env="SEC_DATA_URL",
            per_minute=480,
            burst=5,
            run_budget=600,
            limit_group="sec"
        ),
        Source(
            name="sec_archives",
            base_url="https://www.sec.gov",
            base_url_env="SEC_ARCHIVES_URL",
            per_minute=480,
            burst=5,
            run_budget=600,
            limit_group="sec"
        ),
        # Free plan: 60 calls a minute (TDD §6).
        Source(
            name="finnhub",
            base_url="https://finnhub.io/api/v1",
            base_url_env="FINNHUB_BASE_URL",
            per_minute=50,
            burst=5,
            run_budget=150
        ),
        # 120 a minute per key is reported by client libraries, not by FRED's own docs,
        # so pace at half that until a live run confirms it.
        Source(
            name="fred",
            base_url="https://api.stlouisfed.org/fred",
            base_url_env="FRED_BASE_URL",
            per_minute=60,
            burst=5,
            run_budget=40
        ),
        # Two pages a week; Wikimedia asks clients to keep request rates low.
        Source(
            name="wikipedia",
            base_url="https://en.wikipedia.org",
            base_url_env="WIKIPEDIA_BASE_URL",
            per_minute=30,
            burst=2,
            run_budget=10
        )
    ]
};

glob DATASETS: dict[str, Dataset] = {
    d.name: d
    for d in [
        # Daily decisions use prior-day bars; four days covers a three-day weekend.
        Dataset(name="alpaca.bars", source="alpaca_data", max_age_hours=4 * DAY),
        Dataset(
            name="alpaca.news",
            source="alpaca_data",
            max_age_hours=7 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        Dataset(
            name="alpaca.assets",
            source="alpaca_trading",
            max_age_hours=2 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        Dataset(
            name="alpaca.calendar",
            source="alpaca_trading",
            max_age_hours=2 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        # The filing index and company facts change with every new filing.
        Dataset(
            name="sec.submissions",
            source="sec_data",
            max_age_hours=2 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        # A 10-Q can be about 135 days old: a quarter plus the filing deadline.
        Dataset(
            name="sec.companyfacts",
            source="sec_data",
            max_age_hours=150 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        # A filed document never changes; how old it may be is the collector's window.
        Dataset(name="sec.filing", source="sec_archives", max_age_hours=150 * DAY),
        Dataset(
            name="sec.tickers",
            source="sec_archives",
            max_age_hours=8 * DAY,
            cache_ttl_hours=7 * DAY
        ),
        Dataset(
            name="finnhub.news",
            source="finnhub",
            max_age_hours=7 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        Dataset(
            name="finnhub.earnings_calendar",
            source="finnhub",
            max_age_hours=2 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        # Recommendation trends are monthly.
        Dataset(
            name="finnhub.recommendations",
            source="finnhub",
            max_age_hours=45 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        Dataset(
            name="finnhub.eps_surprises",
            source="finnhub",
            max_age_hours=150 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        Dataset(
            name="finnhub.metrics",
            source="finnhub",
            max_age_hours=7 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        # Daily series such as DGS10 and VIXCLS post a day late; five days covers a holiday.
        Dataset(
            name="fred.daily",
            source="fred",
            max_age_hours=5 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        # A monthly observation is dated the first of its month and released mid next month.
        Dataset(
            name="fred.monthly",
            source="fred",
            max_age_hours=75 * DAY,
            cache_ttl_hours=24 * HOUR
        ),
        # Refreshed weekly (TDD §6).
        Dataset(
            name="wikipedia.constituents",
            source="wikipedia",
            max_age_hours=8 * DAY,
            cache_ttl_hours=7 * DAY
        ),
        Dataset(name="wikipedia.history", source="wikipedia", max_age_hours=8 * DAY, cache_ttl_hours=7 * DAY)
    ]
};
