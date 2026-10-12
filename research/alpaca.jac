"""Alpaca market data, tradable assets, and the market calendar (TDD §5 steps 2 and 3, §6).

Raw REST through SourceClient rather than the alpaca-py SDK: the SDK makes its own HTTP
calls, which would bypass the raw cache, the shared rate limit, the run budget, and fixture
recording, and it would add a dependency for four GET endpoints.

- Daily bars come from the multi-symbol endpoint on the SIP feed (every U.S. exchange, so
  volumes are whole-market), adjusted for splits and dividends. The free plan withholds only
  the latest 15 minutes of SIP data, and bars end at a completed session.
- The latest trade comes from the free real-time IEX feed, for the executor's limit prices.
- Assets and the calendar come from the paper trading API.

Keys go in headers, which the cache and recorded fixtures never keep.
"""
import json;
import from datetime { date, datetime, time, timezone }
import from urllib.parse { urlencode }
import from zoneinfo { ZoneInfo }
import from models.research { Stamped }
import from research.collector {
    Fetched,
    RunBudget,
    SourceClient,
    env_key,
    parse_utc
}
import from research.sources { DATASETS, SOURCES }

glob BARS_PER_PAGE: int = 10000;
# A request with all 503 constituents worked (checked 2026-10-08); larger lists are split.
glob SYMBOLS_PER_REQUEST: int = 600;
glob REGULAR_CLOSE: str = "16:00";
# Extended hours end at 20:00 New York time, and the free plan withholds the latest 15
# minutes of SIP data, so a day's bar is final, and may be asked for, from 20:15.
glob EXTENDED_CLOSE: time = time(20, 0);
glob BARS_FINAL_AT: time = time(20, 15);
glob MARKET_TZ: ZoneInfo = ZoneInfo("America/New_York");

"""One trading day's bar. `day` is the session date in New York."""
obj Bar {
    has day: str,
        open: float,
        high: float,
        low: float,
        close: float,
        volume: float,
        trades: int,
        vwap: float;
}

"""Daily bars for one symbol, oldest first, published as of the newest bar's session."""
obj BarSeries(Stamped) {
    has symbol: str,
        bars: list[Bar];
}

obj Asset(Stamped) {
    has symbol: str,
        name: str,
        exchange: str,
        tradable: bool,
        fractionable: bool,
        shortable: bool,
        easy_to_borrow: bool;
}

"""One trading day. Times are New York wall-clock "HH:MM"; holidays have no entry."""
obj MarketDay(Stamped) {
    has day: str,
        open: str,
        close: str,
        early_close: bool;
}

obj LatestTrade(Stamped) {
    has symbol: str,
        price: float,
        size: float,
        at: str,
        exchange: str;
}

def alpaca_headers -> dict[str, str] {
    return {
        "APCA-API-KEY-ID": env_key("alpaca", "ALPACA_API_KEY"),
        "APCA-API-SECRET-KEY": env_key("alpaca", "ALPACA_SECRET_KEY")
    };
}

def alpaca_data_client -> SourceClient {
    return SourceClient(source=SOURCES["alpaca_data"], headers=alpaca_headers());
}

def alpaca_trading_client -> SourceClient {
    return SourceClient(source=SOURCES["alpaca_trading"], headers=alpaca_headers());
}

"""Whether the bar for `day` (ISO date) can no longer change: an earlier day, or today
after BARS_FINAL_AT in New York."""
def bars_final(day: str, now: datetime | None = None) -> bool {
    local = (now or datetime.now(MARKET_TZ)).astimezone(MARKET_TZ);
    today = local.date().isoformat();
    return day < today or (day == today and local.time() >= BARS_FINAL_AT);
}

"""Daily bars from `start` through `end` (ISO dates, inclusive) for each symbol, and a gap
for each symbol with none.

`end` must be a session whose bar is final (see bars_final): its bars are then cached for
good. Freshness is the caller's to check with split_fresh, since a backtest asks
for old bars on purpose.
"""
def daily_bars(
    symbols: list[str],
    start: str,
    end: str,
    budget: RunBudget,
    client: SourceClient | None = None
) -> tuple[list[BarSeries], list[str]] {
    if not bars_final(end) {
        raise ValueError(f"end {end} is not a completed session; its bar is final after {BARS_FINAL_AT:%H:%M} New York time");
    }
    data = client or alpaca_data_client();
    dataset = DATASETS["alpaca.bars"];
    # A date-only end means the end of that day, which is still in the future this evening and
    # is refused as recent SIP data; the end of extended hours is the same bar, and is past.
    closed = datetime.combine(date.fromisoformat(end), EXTENDED_CLOSE, MARKET_TZ).astimezone(timezone.utc);
    query = {"timeframe": "1Day", "start": start, "end": closed.strftime("%Y-%m-%dT%H:%M:%SZ"), "adjustment": "all", "feed": "sip"};
    wanted = sorted(set(symbols));
    bars: dict[str, list[Bar]] = {};
    pages: dict[str, Fetched] = {};
    for i in range(0, len(wanted), SYMBOLS_PER_REQUEST) {
        chunk = wanted[i:i + SYMBOLS_PER_REQUEST];
        token = "";
        while True {
            params: dict[str, str | int | float] = {**query, "symbols": ",".join(chunk), "limit": BARS_PER_PAGE};
            if token {
                params["page_token"] = token;
            }
            fetched = data.get(dataset, "/v2/stocks/bars", budget, params=params, day=end, check=_check_keyed("bars"));
            page = json.loads(fetched.body);
            for (symbol, rows) in (page["bars"] or {}).items() {
                bars.setdefault(symbol, []).extend(_bar(row) for row in rows);
                pages.setdefault(symbol, fetched);
            }
            token = page.get("next_page_token") or "";
            if not token {
                break;
            }
        }
    }
    found: list[BarSeries] = [];
    gaps: list[str] = [];
    for symbol in wanted {
        if not bars.get(symbol) {
            gaps.append(f"alpaca.bars: no daily bars for {symbol} from {start} to {end}");
            continue;
        }
        series = sorted(bars[symbol], key=lambda (b: Bar) { b.day; });
        cite = SOURCES["alpaca_data"].base_url + "/v2/stocks/bars?" + urlencode({**query, "symbols": symbol});
        found.append(
            BarSeries(
                symbol=symbol,
                bars=series,
                stamp=pages[symbol].stamp(series[-1].day, source_url=cite)
            )
        );
    }
    return (found, gaps);
}

"""Every active U.S. equity Alpaca lists, by symbol, with whether it can be traded."""
def assets(budget: RunBudget, client: SourceClient | None = None) -> dict[str, Asset] {
    fetched = (client or alpaca_trading_client()).get(
        DATASETS["alpaca.assets"],
        "/v2/assets",
        budget,
        params={"status": "active", "asset_class": "us_equity"},
        check=_check_list
    );
    return {
        row["symbol"]: Asset(
            symbol=row["symbol"],
            name=row.get("name") or "",
            exchange=row.get("exchange") or "",
            tradable=bool(row.get("tradable")),
            fractionable=bool(row.get("fractionable")),
            shortable=bool(row.get("shortable")),
            easy_to_borrow=bool(row.get("easy_to_borrow")),
            stamp=fetched.stamp(fetched.fetched_at)
        )
        for row in json.loads(fetched.body)
    };
}

"""Trading days from `start` through `end` (ISO dates), with early closes marked."""
def market_calendar(
    start: str,
    end: str,
    budget: RunBudget,
    client: SourceClient | None = None
) -> list[MarketDay] {
    fetched = (client or alpaca_trading_client()).get(
        DATASETS["alpaca.calendar"],
        "/v2/calendar",
        budget,
        params={"start": start, "end": end},
        check=_check_list
    );
    return [
        MarketDay(
            day=row["date"],
            open=row["open"],
            close=row["close"],
            early_close=row["close"] < REGULAR_CLOSE,
            stamp=fetched.stamp(fetched.fetched_at)
        )
        for row in json.loads(fetched.body)
    ];
}

"""The last IEX trade for each symbol, and a gap for each symbol without one."""
def latest_trades(symbols: list[str], budget: RunBudget, client: SourceClient | None = None) -> tuple[list[LatestTrade], list[str]] {
    data = client or alpaca_data_client();
    wanted = sorted(set(symbols));
    trades: list[LatestTrade] = [];
    gaps: list[str] = [];
    for i in range(0, len(wanted), SYMBOLS_PER_REQUEST) {
        chunk = wanted[i:i + SYMBOLS_PER_REQUEST];
        fetched = data.get(
            DATASETS["alpaca.latest_trade"],
            "/v2/stocks/trades/latest",
            budget,
            params={"symbols": ",".join(chunk), "feed": "iex"},
            check=_check_keyed("trades")
        );
        found: dict[str, dict[str, str | float]] = json.loads(fetched.body)["trades"] or {};
        for symbol in chunk {
            row = found.get(symbol);
            if not row {
                gaps.append(f"alpaca.latest_trade: no IEX trade for {symbol}");
                continue;
            }
            cite = SOURCES["alpaca_data"].base_url + "/v2/stocks/trades/latest?" + urlencode({"symbols": symbol, "feed": "iex"});
            trades.append(
                LatestTrade(
                    symbol=symbol,
                    price=float(row["p"]),
                    size=float(row["s"]),
                    at=str(row["t"]),
                    exchange=str(row.get("x") or ""),
                    stamp=fetched.stamp(str(row["t"]), source_url=cite)
                )
            );
        }
    }
    return (trades, gaps);
}

def _bar(row: dict[str, float | int | str]) -> Bar {
    return Bar(
        day=parse_utc(str(row["t"])).astimezone(MARKET_TZ).date().isoformat(),
        open=float(row["o"]),
        high=float(row["h"]),
        low=float(row["l"]),
        close=float(row["c"]),
        volume=float(row["v"]),
        trades=int(row.get("n") or 0),
        vwap=float(row.get("vw") or 0.0)
    );
}

"""A check that the body is a JSON object with `key`, as bars and trades are."""
def _check_keyed(key: str) -> Callable[[str], str] {
    def check(body: str) -> str {
        try {
            parsed = json.loads(body);
        } except ValueError {
            return f"not JSON: {body[:200]}";
        }
        return "" if isinstance(parsed, dict) and key in parsed else f"no {key!r} in {body[:200]}";
    }
    return check;
}

def _check_list(body: str) -> str {
    try {
        parsed = json.loads(body);
    } except ValueError {
        return f"not JSON: {body[:200]}";
    }
    return "" if isinstance(parsed, list) else f"expected a list: {body[:200]}";
}
