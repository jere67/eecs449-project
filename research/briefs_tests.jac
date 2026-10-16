"""The research briefs: what each sub-agent reads, its citations, and its length cap. Pure
functions over hand-built collector outputs; no network."""
import from models.agents { Domain }
import from models.research { Stamp }
import from research.alpaca_news { Article }
import from research.briefs {
    Brief,
    FundamentalsInputs,
    MAX_ARTICLES,
    MAX_BRIEF_CHARS,
    MacroInputs,
    MarketInputs,
    NewsInputs,
    change,
    fundamentals_brief,
    macro_brief,
    market_brief,
    news_brief,
    regime_inputs,
    pct,
    pick_articles,
    usd
}
import from research.finnhub { EarningsDate, KeyMetrics }
import from research.indicators { Technicals }
import from research.sec { Filing, Fundamentals, InsiderTrade, ReportedValue }

glob AS_OF: str = "2026-10-15";

def stamp(url: str, published: str = "2026-10-14") -> Stamp {
    return Stamp(source="test", dataset="test", source_url=url, published_at=published, fetched_at="2026-10-15T11:00:00+00:00");
}

def technicals(symbol: str) -> Technicals {
    return Technicals(
        symbol=symbol,
        as_of="2026-10-14",
        bars=251,
        close=110.0,
        sma_20=105.0,
        sma_200=100.0,
        rsi_14=61.25,
        momentum_20=0.042,
        rs_spy_20=-0.011,
        stamp=stamp(f"https://data.alpaca.markets/v2/stocks/bars?symbols={symbol}")
    );
}

def article(n: int, headline: str, created: str, url: str = "") -> Article {
    link = url or f"https://news.test/{n}";
    return Article(
        id=n,
        headline=headline,
        summary="Summary.",
        content="Body " * 400,
        author="",
        source="benzinga",
        url=link,
        symbols=["AAPL"],
        created_at=created,
        updated_at=created,
        stamp=stamp(link, created)
    );
}

def trade(insider: str, code: str, shares: float, price: float, filed: str, url: str) -> InsiderTrade {
    return InsiderTrade(
        symbol="AAPL",
        insider=insider,
        role="CEO",
        day="2026-10-01",
        code=code,
        acquired=code == "P",
        shares=shares,
        price=price,
        shares_after=1000.0,
        planned=code == "S",
        filed=filed,
        filing_lag_days=2,
        stamp=stamp(url, filed)
    );
}

test "the market brief cites the bars and says each indicator in words" {
    brief = market_brief("AAPL", AS_OF, MarketInputs(stock=technicals("AAPL"), spy=technicals("SPY"), sector=None, sector_etf="XLK"));
    assert brief.domain == Domain.MARKET;
    text = brief.render();
    assert text.startswith("[1] AAPL technical indicators from daily bars (computed in code)\nsource_url: https://data.alpaca.markets/v2/stocks/bars?symbols=AAPL\npublished: 2026-10-14\n");
    assert "Close on 2026-10-14: $110.00; 251 daily bars of history." in text;
    assert "200-day $100.00 (close is +10.0% from it)" in text;
    assert "50-day n/a" in text;
    assert "RSI(14): 61.2" in text or "RSI(14): 61.3" in text;
    assert "Momentum: 20-day +4.2%" in text and "Relative strength against SPY: 20-day -1.1%" in text;
    assert "[2] SPY (S&P 500 fund) trend, for context" in text;
    assert brief.gaps == ["market: no bars for XLK (sector fund), so no relative strength against it"];
    assert set(brief.published_by_url()) == {
        "https://data.alpaca.markets/v2/stocks/bars?symbols=AAPL", "https://data.alpaca.markets/v2/stocks/bars?symbols=SPY"
    };
}

test "a ticker without bars has an empty market brief and says why" {
    brief = market_brief("ZZZZ", AS_OF, MarketInputs(gaps=["alpaca.bars: no daily bars for ZZZZ"]));
    assert brief.kept() == [];
    assert brief.render() == "(no sources)";
    assert brief.all_gaps()[:2] == ["alpaca.bars: no daily bars for ZZZZ", "market: no daily bars for ZZZZ, so no indicators"];
}

test "SEC figures are grouped by the filing that reported them" {
    q = "https://www.sec.gov/Archives/edgar/data/320193/q-index.htm";
    k = "https://www.sec.gov/Archives/edgar/data/320193/k-index.htm";
    sec = Fundamentals(
        symbol="AAPL",
        cik="0000320193",
        company="Apple Inc.",
        values=[
            ReportedValue(name="revenue_quarter", value=109417000000.0, unit="USD", period="quarter 2026-03-29 to 2026-06-27", filed="2026-07-31", source_url=q),
            ReportedValue(name="revenue_growth_yoy", value=0.1636, unit="fraction", period="quarter to 2026-06-27 vs. quarter to 2025-06-28", filed="2026-07-31", source_url=q),
            ReportedValue(name="gross_margin_ttm", value=0.4865, unit="fraction", period="twelve months to 2026-06-27", filed="2026-07-31", source_url=q),
            ReportedValue(name="eps_diluted_quarter", value=2.02, unit="USD/share", period="quarter 2026-03-29 to 2026-06-27", filed="2026-07-31", source_url=q),
            ReportedValue(name="shares_outstanding", value=14594180000.0, unit="shares", period="as of 2025-10-17", filed="2025-10-31", source_url=k)
        ],
        stamp=stamp(q, "2026-07-31")
    );
    metrics = KeyMetrics(symbol="AAPL", values={"peTTM": 38.25, "marketCapitalization": 4870000.0, "grossMarginTTM": 48.7}, stamp=stamp("https://finnhub.io/api/v1/stock/metric?symbol=AAPL"));
    brief = fundamentals_brief("AAPL", AS_OF, FundamentalsInputs(sec=sec, metrics=metrics, trades=None));
    labels = [i.label for i in brief.kept()];
    assert labels[:3] == [
        "AAPL financial statements reported to the SEC (filed 2026-07-31)",
        "AAPL financial statements reported to the SEC (filed 2025-10-31)",
        "AAPL valuation and quality metrics (Finnhub)"
    ];
    q_text = brief.kept()[0].text;
    assert "Revenue, latest quarter: $109.4B (quarter 2026-03-29 to 2026-06-27)." in q_text;
    assert "Revenue growth, year over year: +16.4%" in q_text;
    assert "Gross margin, trailing 12 months: 48.6%" in q_text or "Gross margin, trailing 12 months: 48.7%" in q_text;
    assert "Diluted EPS, latest quarter: $2.02 per share" in q_text;
    assert brief.kept()[0].published == "2026-07-31";
    finnhub = brief.kept()[2].text;
    assert "Market capitalization: $4.9T." in finnhub and "Price to earnings (trailing 12 months): 38.25x." in finnhub and "Gross margin (trailing): 48.7%." in finnhub;
    assert "fundamentals: insider transactions for AAPL are unavailable" in brief.gaps;
    assert "fundamentals: no EPS surprise history for AAPL" in brief.gaps;
}

test "insider trades become a summary and the largest open-market trades, each citing its Form 4" {
    trades = [
        trade("Cook", "S", 1000.0, 330.0, "2026-10-05", "https://sec.test/a"),
        trade("Cook", "F", 500.0, 330.0, "2026-10-05", "https://sec.test/a"),
        trade("Ternus", "S", 5000.0, 331.0, "2026-10-06", "https://sec.test/b"),
        trade("Levinson", "P", 100.0, 300.0, "2026-09-20", "https://sec.test/c")
    ];
    brief = fundamentals_brief("AAPL", AS_OF, FundamentalsInputs(trades=trades, insider_since="2026-07-17"));
    summary = [i for i in brief.kept() if "insider activity summary" in i.label][0];
    assert summary.source_url == "https://sec.test/b" and summary.published == "2026-10-06";
    assert "Form 4 transactions in common stock filed since 2026-07-17: 4, by 3 insiders." in summary.text;
    assert "Open-market purchases: 1 trades by 1 insiders, 100 shares, about $30,000.00." in summary.text;
    assert "Open-market sales: 2 trades by 2 insiders, 6,000 shares, about $2.0M." in summary.text;
    assert "Other transactions (mostly compensation): shares withheld for tax x1." in summary.text;
    assert "2 of 3 open-market trades were filed as made under a Rule 10b5-1 trading plan" in summary.text;
    singles = [i for i in brief.kept() if i.label.startswith("AAPL Form 4 filed")];
    assert [i.source_url for i in singles] == ["https://sec.test/b", "https://sec.test/a", "https://sec.test/c"];
    assert singles[0].text == "Ternus (CEO): open-market sale of 5,000 shares at $331.00 on 2026-10-01 under a Rule 10b5-1 plan; holds 1,000 shares after; filed 2 days later.";
}

test "no insider trades is a fact, not a gap" {
    brief = fundamentals_brief("AAPL", AS_OF, FundamentalsInputs(trades=[], insider_since="2026-07-17"));
    found = [i for i in brief.kept() if "insider transactions" in i.label][0];
    assert found.text == "No Form 4 transactions in common stock were filed from 2026-07-17 to 2026-10-15.";
    assert not [g for g in brief.gaps if "insider" in g];
}

test "the news brief puts the calendar and filings first, then distinct articles as untrusted data" {
    earnings = EarningsDate(symbol="AAPL", day="2026-10-29", hour="amc", quarter=4, year=2026, eps_estimate=1.95, eps_actual=None, revenue_estimate=1.2e11, revenue_actual=None, stamp=stamp("https://finnhub.io/api/v1/calendar/earnings?from=2026-10-15&to=2026-10-21", "2026-10-15T11:00:00+00:00"));
    filing = Filing(symbol="AAPL", cik="0000320193", form="8-K", accession="0000320193-26-000030", filed="2026-09-01", report_date="", accepted_at="", items=["5.02"], primary_document="x.htm", stamp=stamp("https://sec.test/8k", "2026-09-01"));
    articles = [
        article(1, "Apple beats", "2026-10-14T12:00:00Z"),
        article(2, "Apple  BEATS", "2026-10-14T11:00:00Z"),
        article(3, "Older story", "2026-10-10T12:00:00Z")
    ];
    brief = news_brief("AAPL", AS_OF, NewsInputs(next_earnings=earnings, sessions_until=10, events=[filing], articles=articles));
    items = brief.kept();
    assert items[0].text == "Fiscal Q4 2026 results are scheduled for 2026-10-29, after the close: 10 trading sessions after the run date. Consensus EPS estimate: $1.95. Consensus revenue estimate: $120.0B.";
    assert items[1].text == "Form 8-K filed 2026-09-01 reporting: director or officer change.";
    assert [i.source_url for i in items[2:]] == ["https://news.test/1", "https://news.test/3"];
    assert items[2].text.startswith('<untrusted-data kind="news article" source="benzinga" published="2026-10-14T12:00:00Z">\nApple beats');
    assert len(items[2].text) < 1400;
}

test "articles repeated across sources are kept once, newest first" {
    same_url = [article(1, "A", "2026-10-14T10:00:00Z", "https://x.test/1"), article(2, "B", "2026-10-14T12:00:00Z", "https://x.test/1")];
    assert [a.headline for a in pick_articles(same_url, 5)] == ["B"];
    many = [article(i, f"Story {i}", f"2026-10-{10 + i % 5:02d}T{i:02d}:00:00Z") for i in range(20)];
    assert len(pick_articles(many, MAX_ARTICLES)) == MAX_ARTICLES;
}

test "the length cap keeps the first sources, and only those can be cited" {
    brief = Brief(ticker="AAPL", domain=Domain.NEWS, as_of=AS_OF);
    for i in range(40) {
        brief.add(f"Source {i}", f"https://x.test/{i}", "2026-10-14", "word " * 200);
    }
    kept = brief.kept();
    assert 0 < len(kept) < 40;
    assert len(brief.render()) <= MAX_BRIEF_CHARS;
    assert [i.label for i in kept] == [f"Source {i}" for i in range(len(kept))];
    assert f"https://x.test/{len(kept)}" not in brief.published_by_url();
    assert brief.all_gaps() == [f"{40 - len(kept)} lower-priority sources were left out to fit the length cap"];
    brief.add("Empty", "https://x.test/empty", "2026-10-14", "  ");
    brief.add("No URL", "", "2026-10-14", "text");
    assert len(brief.items) == 40;
}

test "numbers read at a sensible scale" {
    assert [usd(1.234e12), usd(-5.6e9), usd(12_340_000.0), usd(331.44), usd(None)] == ["$1.2T", "-$5.6B", "$12.3M", "$331.44", "n/a"];
    assert [pct(0.1234), pct(0.5, 0), change(0.042), change(-0.011), change(None)] == ["12.3%", "50%", "+4.2%", "-1.1%", "n/a"];
}

def macro_inputs -> MacroInputs {
    spy = technicals("SPY");
    spy.realized_vol_20 = 0.142;
    tlt = technicals("TLT");
    (tlt.momentum_20, tlt.momentum_60) = (-0.031, -0.054);
    tip = technicals("TIP");
    (tip.rs_sector_20, tip.rs_sector_60) = (0.004, 0.012);
    xlk = technicals("XLK");
    xlk.rs_spy_60 = 0.05;
    xle = technicals("XLE");
    xle.rs_spy_60 = -0.03;
    return MacroInputs(spy=spy, bonds={"TIP": tip, "TLT": tlt}, sectors={"XLE": xle, "XLK": xlk});
}

test "the macro brief puts market risk first, then Treasury funds, then sector rotation" {
    brief = macro_brief(AS_OF, macro_inputs());
    assert brief.domain == Domain.MACRO;
    texts = {i.label: i.text for i in brief.kept()};
    assert list(texts) == [
        "SPY (S&P 500 fund) trend",
        "TLT (20+ year Treasury fund)",
        "TIP (inflation-protected Treasury fund)",
        "XLK (Information Technology sector fund)",
        "XLE (Energy sector fund)"
    ];
    spy = texts["SPY (S&P 500 fund) trend"];
    assert spy.startswith("Close on 2026-10-14: $110.00, above its 200-day average $100.00.");
    assert "Realized volatility (20-day, annualized): 14.2%." in spy;
    tlt = texts["TLT (20+ year Treasury fund)"];
    assert "Return: 20-day -3.1%, 60-day -5.4% (a falling fund means its yields rose)." in tlt;
    assert "Relative strength" not in tlt;
    assert "Relative strength against IEF, of similar maturity: 20-day +0.4%, 60-day +1.2%" in texts["TIP (inflation-protected Treasury fund)"];
    assert texts["XLK (Information Technology sector fund)"].startswith("Ranks 1 of 2 sector funds by 60-day strength against SPY.");
    assert texts["XLE (Energy sector fund)"].startswith("Ranks 2 of 2");
    assert "macro: no bars for Treasury funds SHY, IEF" in brief.gaps;
    assert [g for g in brief.gaps if g.startswith("macro: no bars for sector funds")][0].startswith("macro: no bars for sector funds XLB, XLC, XLF");
}

test "the regime inputs come from SPY's bars, not from the model" {
    found = regime_inputs(macro_inputs());
    assert (found.spy_close, found.spy_sma_200, found.spy_vol_20, found.spy_as_of) == (110.0, 100.0, 0.142, "2026-10-14");
    assert found.spy_above_200d() is True;
    empty = regime_inputs(MacroInputs());
    assert empty.spy_above_200d() is None and empty.spy_vol_20 is None;
    assert "macro: no SPY bars, so no market trend or regime check" in macro_brief(AS_OF, MacroInputs()).gaps;
}
