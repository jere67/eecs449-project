"""Indicators against values computed by hand (shown in each test), on short series with
small windows, and the summary over recorded Alpaca bars."""
import json;
import math;
import from pathlib { Path }
import from models.research { Stamp }
import from research.alpaca { Bar, BarSeries }
import from research.indicators {
    SECTOR_ETFS,
    atr,
    bollinger_width,
    dollar_volume,
    ema_series,
    macd,
    momentum,
    range_position,
    realized_vol,
    relative_strength,
    relative_volume,
    rsi,
    sma,
    summarize,
    wilder_series
}

glob BARS_FIXTURE: Path = next((Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "alpaca").glob("alpaca.bars-*.json"));

def close_to(a: float | None, b: float) -> bool {
    return a is not None and math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-12);
}

def stamp -> Stamp {
    return Stamp(source="alpaca_data", dataset="alpaca.bars", source_url="u", published_at="", fetched_at="");
}

def bar(day: str, close: float, high: float = 0.0, low: float = 0.0, volume: float = 1.0) -> Bar {
    return Bar(day=day, open=close, high=high or close, low=low or close, close=close, volume=volume, trades=1, vwap=close);
}

"""The recorded bars for `symbol`, as the collector reads them."""
def recorded(symbol: str) -> BarSeries {
    rows = json.loads(json.loads(BARS_FIXTURE.read_text())["body"])["bars"][symbol];
    return BarSeries(
        symbol=symbol,
        bars=[Bar(day=r["t"][:10], open=r["o"], high=r["h"], low=r["l"], close=r["c"], volume=r["v"], trades=r["n"], vwap=r["vw"]) for r in rows],
        stamp=stamp()
    );
}

test "simple and exponential averages" {
    assert sma([1.0, 2.0, 3.0, 4.0, 5.0], 3) == 4.0;
    assert sma([1.0, 2.0], 3) is None;
    # Seed (1 + 2 + 3) / 3 = 2, then 2 + 0.5 * (5 - 2) = 3.5 with alpha = 2 / (3 + 1).
    assert ema_series([1.0, 2.0, 3.0, 5.0], 3) == [2.0, 3.5];
    # Seed (2 + 4) / 2 = 3, then (3 * 1 + 8) / 2 = 5.5.
    assert wilder_series([2.0, 4.0, 8.0], 2) == [3.0, 5.5];
}

test "MACD on a doubling series" {
    # EMA(2) from index 1: 1.5, 19/6, 115/18, 691/54, 4147/162.
    # EMA(3) from index 2: 7/3, 31/6, 127/12, 511/24.
    # MACD line: 5/6, 11/9, 239/108, 2791/648; signal EMA(2) seeded 37/36, then 589/324, then 845/243.
    result = macd([1.0, 2.0, 4.0, 8.0, 16.0, 32.0], fast=2, slow=3, signal=2);
    assert result is not None;
    (line, signal, hist) = result;
    assert close_to(line, 2791 / 648) and close_to(signal, 845 / 243);
    assert close_to(hist, 2791 / 648 - 845 / 243);
    assert macd([1.0] * 33) is None and macd([1.0] * 34) is not None;
}

test "RSI with Wilder smoothing" {
    # Changes +1, -1, +2, +1. Gains average (1 + 0) / 2 = 0.5, then 1.25, then 1.125;
    # losses 0.5, then 0.25, then 0.125. RS = 9, so RSI = 100 - 100 / 10 = 90.
    assert close_to(rsi([10.0, 11.0, 10.0, 12.0, 13.0], 2), 90.0);
    assert rsi([1.0, 2.0, 3.0, 4.0], 2) == 100.0;
    assert rsi([5.0, 5.0, 5.0], 2) == 50.0;
    assert rsi([1.0, 2.0], 2) is None;
}

test "average true range counts gaps from the previous close" {
    # True ranges: max(2, 2, 0) = 2, max(2, 2, 0) = 2, max(4, 0, 4) = 4. Seed 2, then (2 + 4) / 2 = 3.
    highs = [10.0, 11.0, 12.0, 11.0];
    lows = [8.0, 9.0, 10.0, 7.0];
    closes = [9.0, 10.0, 11.0, 8.0];
    assert atr(highs, lows, closes, 2) == 3.0;
    assert atr(highs[:2], lows[:2], closes[:2], 2) is None;
}

test "Bollinger width, range position, and momentum" {
    # Mean 3, population deviation sqrt(2): width 4 * sqrt(2) / 3.
    assert close_to(bollinger_width([1.0, 2.0, 3.0, 4.0, 5.0], 5, 2.0), 4 * math.sqrt(2) / 3);
    assert range_position([10.0, 12.0, 11.0], [8.0, 9.0, 7.0], 9.5, 3) == 0.5;
    assert range_position([10.0], [10.0], 10.0, 3) is None;
    assert close_to(momentum([100.0, 110.0, 121.0], 2), 0.21);
    assert momentum([100.0, 110.0], 2) is None;
}

test "volume and volatility measures" {
    assert relative_volume([1.0, 1.0, 3.0, 3.0], 2, 4) == 1.5;
    assert relative_volume([1.0, 1.0, 3.0], 2, 4) is None;
    assert dollar_volume([10.0, 20.0], [5.0, 1.0], 2) == 35.0;
    # Log returns ln(1.1) and ln(0.9); their sample deviation is |difference| / sqrt(2).
    expected = abs(math.log(1.1) - math.log(0.9)) / math.sqrt(2) * math.sqrt(252);
    assert close_to(realized_vol([100.0, 110.0, 99.0], 2), expected);
    assert realized_vol([100.0, 110.0], 2) is None;
}

test "relative strength pairs sessions by date" {
    stock = [bar("d0", 100.0), bar("d1", 110.0), bar("d2", 121.0)];
    bench = [bar("d0", 100.0), bar("d1", 100.0), bar("d2", 110.0)];
    # Stock +21%, benchmark +10%: 1.21 / 1.10 - 1 = 0.1.
    assert close_to(relative_strength(stock, bench, 2), 0.1);
    # A session the benchmark lacks is skipped, so only two shared sessions remain.
    assert relative_strength(stock, [bench[0], bench[2]], 2) is None;
    assert close_to(relative_strength(stock, [bench[0], bench[2]], 1), 1.21 / 1.1 - 1);
}

test "the summary uses what the history allows" {
    aapl = recorded("AAPL");
    summary = summarize(aapl, spy=recorded("SPY"));
    assert summary.symbol == "AAPL" and summary.as_of == "2026-10-07" and summary.bars == 26;
    assert summary.close == 336.67;
    assert summary.sma_20 is not None and summary.sma_50 is None and summary.sma_200 is None;
    assert summary.rsi_14 is not None and 0 <= summary.rsi_14 <= 100;
    assert summary.atr_14 is not None and summary.atr_pct is not None and summary.atr_pct < 0.2;
    assert summary.momentum_20 is not None and summary.momentum_60 is None;
    assert summary.macd is None and summary.rvol_5 is None;
    assert summary.rs_spy_20 is not None and summary.rs_spy_60 is None and summary.rs_sector_20 is None;
    assert summary.range_52w_position is not None and 0 <= summary.range_52w_position <= 1;
    assert summary.dollar_volume_20 is not None and summary.dollar_volume_20 > 1e9;
    assert summary.stamp.dataset == "alpaca.bars";
}

test "every GICS sector has a sector fund" {
    assert len(SECTOR_ETFS) == 11 and len(set(SECTOR_ETFS.values())) == 11;
}
