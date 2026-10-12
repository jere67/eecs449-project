"""Technical indicators computed in code from daily bars (TDD §6, research sub-agents).

Agents never see raw bars (TDD §3, rule 12): the Market sub-agent and the screener read the
compact Technicals summary instead. Every function is pure and returns None when there is
too little history, so a recent listing gets fewer indicators rather than wrong ones.

These are plain Python rather than pandas: each is a few lines over at most a year of
closes, which keeps them dependency-free, fully typed, and checked against hand-computed
values in indicators_tests.jac. Conventions follow the usual definitions:

- EMAs (MACD) and Wilder averages (RSI, ATR) are seeded with the simple mean of their first
  window, so a value depends only on the bars given.
- Bollinger width is (upper - lower) / middle with the population standard deviation.
- Realized volatility is the sample standard deviation of daily log returns, annualized.
"""
import math;
import statistics;
import from models.research { Stamped }
import from research.alpaca { Bar, BarSeries }

glob TRADING_DAYS_PER_YEAR: int = 252;

# The SPDR sector fund for each GICS sector, the benchmark for sector-relative strength.
glob SECTOR_ETFS: dict[str, str] = {
    "Communication Services": "XLC",
    "Consumer Discretionary": "XLY",
    "Consumer Staples": "XLP",
    "Energy": "XLE",
    "Financials": "XLF",
    "Health Care": "XLV",
    "Industrials": "XLI",
    "Information Technology": "XLK",
    "Materials": "XLB",
    "Real Estate": "XLRE",
    "Utilities": "XLU"
};

"""The indicator summary for one symbol on its newest bar. Returns are fractions (0.05 is
5%), and `rs_*` is the return relative to a benchmark: (1 + stock) / (1 + benchmark) - 1."""
obj Technicals(Stamped) {
    has symbol: str,
        as_of: str,
        bars: int,
        close: float;
    has sma_20: float | None = None,
        sma_50: float | None = None,
        sma_200: float | None = None,
        rsi_14: float | None = None,
        macd: float | None = None,
        macd_signal: float | None = None,
        macd_hist: float | None = None,
        bollinger_width: float | None = None,
        atr_14: float | None = None,
        atr_pct: float | None = None,
        range_52w_position: float | None = None,
        momentum_20: float | None = None,
        momentum_60: float | None = None,
        rvol_5: float | None = None,
        realized_vol_20: float | None = None,
        dollar_volume_20: float | None = None,
        rs_spy_20: float | None = None,
        rs_spy_60: float | None = None,
        rs_sector_20: float | None = None,
        rs_sector_60: float | None = None;
}

"""Every indicator for `series` on its newest bar. Pass SPY's and the sector fund's series
for relative strength; they are matched to the stock by session date."""
def summarize(series: BarSeries, spy: BarSeries | None = None, sector: BarSeries | None = None) -> Technicals {
    bars = series.bars;
    closes = [b.close for b in bars];
    highs = [b.high for b in bars];
    lows = [b.low for b in bars];
    volumes = [b.volume for b in bars];
    trend = macd(closes);
    average_range = atr(highs, lows, closes, 14);
    return Technicals(
        symbol=series.symbol,
        as_of=bars[-1].day,
        bars=len(bars),
        close=closes[-1],
        sma_20=sma(closes, 20),
        sma_50=sma(closes, 50),
        sma_200=sma(closes, 200),
        rsi_14=rsi(closes, 14),
        macd=trend[0] if trend else None,
        macd_signal=trend[1] if trend else None,
        macd_hist=trend[2] if trend else None,
        bollinger_width=bollinger_width(closes, 20, 2.0),
        atr_14=average_range,
        atr_pct=average_range / closes[-1] if average_range is not None and closes[-1] else None,
        range_52w_position=range_position(highs, lows, closes[-1], TRADING_DAYS_PER_YEAR),
        momentum_20=momentum(closes, 20),
        momentum_60=momentum(closes, 60),
        rvol_5=relative_volume(volumes, 5, 60),
        realized_vol_20=realized_vol(closes, 20),
        dollar_volume_20=dollar_volume(closes, volumes, 20),
        rs_spy_20=relative_strength(bars, spy.bars, 20) if spy else None,
        rs_spy_60=relative_strength(bars, spy.bars, 60) if spy else None,
        rs_sector_20=relative_strength(bars, sector.bars, 20) if sector else None,
        rs_sector_60=relative_strength(bars, sector.bars, 60) if sector else None,
        stamp=series.stamp
    );
}

"""The mean of the last `n` values."""
def sma(values: list[float], n: int) -> float | None {
    return statistics.fmean(values[-n:]) if len(values) >= n else None;
}

"""The EMA of `values` from index n - 1 on, seeded with the mean of the first n."""
def ema_series(values: list[float], n: int) -> list[float] {
    if len(values) < n {
        return [];
    }
    alpha = 2.0 / (n + 1);
    out = [statistics.fmean(values[:n])];
    for value in values[n:] {
        out.append(out[-1] + alpha * (value - out[-1]));
    }
    return out;
}

"""Wilder's running average from index n - 1 on, seeded with the mean of the first n."""
def wilder_series(values: list[float], n: int) -> list[float] {
    if len(values) < n {
        return [];
    }
    out = [statistics.fmean(values[:n])];
    for value in values[n:] {
        out.append((out[-1] * (n - 1) + value) / n);
    }
    return out;
}

"""(MACD line, signal line, histogram) on the newest bar."""
def macd(closes: list[float], fast: int = 12, slow: int = 26, signal: int = 9) -> tuple[float, float, float] | None {
    slow_ema = ema_series(closes, slow);
    # Align the fast EMA with the slow one, which starts later.
    fast_ema = ema_series(closes, fast)[slow - fast:];
    line = [f - s for (f, s) in zip(fast_ema, slow_ema)];
    signal_ema = ema_series(line, signal);
    if not signal_ema {
        return None;
    }
    return (line[-1], signal_ema[-1], line[-1] - signal_ema[-1]);
}

"""Wilder's relative strength index, from 0 to 100."""
def rsi(closes: list[float], n: int = 14) -> float | None {
    changes = [b - a for (a, b) in zip(closes, closes[1:])];
    gains = wilder_series([max(c, 0.0) for c in changes], n);
    losses = wilder_series([max(-c, 0.0) for c in changes], n);
    if not gains {
        return None;
    }
    (gain, loss) = (gains[-1], losses[-1]);
    if loss == 0 {
        return 50.0 if gain == 0 else 100.0;
    }
    return 100.0 - 100.0 / (1.0 + gain / loss);
}

"""Wilder's average true range. The first bar has no previous close, so it starts the
true ranges but is not one."""
def atr(highs: list[float], lows: list[float], closes: list[float], n: int = 14) -> float | None {
    ranges = [
        max(highs[i] - lows[i], abs(highs[i] - closes[i - 1]), abs(lows[i] - closes[i - 1]))
        for i in range(1, len(closes))
    ];
    averaged = wilder_series(ranges, n);
    return averaged[-1] if averaged else None;
}

"""Bollinger band width: (upper - lower) / middle for an n-bar band k deviations wide."""
def bollinger_width(closes: list[float], n: int = 20, k: float = 2.0) -> float | None {
    if len(closes) < n {
        return None;
    }
    window = closes[-n:];
    middle = statistics.fmean(window);
    return 2.0 * k * statistics.pstdev(window) / middle if middle else None;
}

"""Where `close` sits in the n-bar high-low range: 0 at the low, 1 at the high. A shorter
history uses all of it."""
def range_position(highs: list[float], lows: list[float], close: float, n: int = 252) -> float | None {
    if not highs {
        return None;
    }
    (high, low) = (max(highs[-n:]), min(lows[-n:]));
    return (close - low) / (high - low) if high > low else None;
}

"""Total return over the last n bars."""
def momentum(closes: list[float], n: int) -> float | None {
    if len(closes) <= n or not closes[-1 - n] {
        return None;
    }
    return closes[-1] / closes[-1 - n] - 1.0;
}

"""Mean volume of the last `short` bars over the mean of the last `long`."""
def relative_volume(volumes: list[float], short: int = 5, long: int = 60) -> float | None {
    if len(volumes) < long {
        return None;
    }
    base = statistics.fmean(volumes[-long:]);
    return statistics.fmean(volumes[-short:]) / base if base else None;
}

"""Annualized standard deviation of the last n daily log returns."""
def realized_vol(closes: list[float], n: int = 20) -> float | None {
    if len(closes) <= n or min(closes[-1 - n:]) <= 0 {
        return None;
    }
    window = closes[-1 - n:];
    returns = [math.log(b / a) for (a, b) in zip(window, window[1:])];
    return statistics.stdev(returns) * math.sqrt(TRADING_DAYS_PER_YEAR);
}

"""Mean daily dollar volume (close times volume) over the last n bars."""
def dollar_volume(closes: list[float], volumes: list[float], n: int = 20) -> float | None {
    if len(closes) < n {
        return None;
    }
    return statistics.fmean([c * v for (c, v) in zip(closes[-n:], volumes[-n:])]);
}

"""The stock's n-bar return relative to the benchmark's, over the sessions both traded:
(1 + stock) / (1 + benchmark) - 1."""
def relative_strength(stock: list[Bar], benchmark: list[Bar], n: int) -> float | None {
    bench = {b.day: b.close for b in benchmark};
    paired = [(b.close, bench[b.day]) for b in stock if b.day in bench];
    if len(paired) <= n {
        return None;
    }
    (s0, b0) = paired[-1 - n];
    (s1, b1) = paired[-1];
    if not (s0 and b0 and b1) {
        return None;
    }
    return (s1 / s0) / (b1 / b0) - 1.0;
}
