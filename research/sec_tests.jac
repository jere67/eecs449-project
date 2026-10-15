"""The SEC EDGAR collector against responses recorded on 2026-10-15 for AAPL (trimmed to what
the tests read), and against hand-built XBRL facts for the period arithmetic. No network."""
import os;
import tempfile;
import from pathlib { Path }
import from jaclang.data.storage.storage { Storage }
import from research.collector { Fetched, MissingKey, RawCache, RunBudget, SourceClient, SourceError, TokenBucket }
import from research.sec {
    Filing,
    Fundamentals,
    ReportedValue,
    cik_map,
    document_html,
    earnings_release,
    eight_ks,
    exhibit_path,
    filings,
    fundamentals,
    insider_trades,
    padded_cik,
    reduce_facts,
    sec_user_agent
}
import from research.sources { SOURCES }
import from tests.fakes.source_server { FakeSource, serve_source }

glob FIXTURES: Path = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "sec";
glob AGENT: str = "trading-agent test@example.edu";
glob AAPL: str = "0000320193";

"""One fake answers both SEC hosts; their paths do not overlap."""
def start_sec -> FakeSource {
    started = serve_source(SOURCES["sec_data"].base_url_env, FIXTURES);
    os.environ[SOURCES["sec_archives"].base_url_env] = os.environ[SOURCES["sec_data"].base_url_env];
    return started;
}

glob fake: FakeSource = start_sec();

def client(source: str) -> SourceClient {
    return SourceClient(
        source=SOURCES[source],
        headers={"User-Agent": AGENT},
        cache=RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage),
        bucket=TokenBucket(per_minute=60000, burst=100),
        backoff_s=0.0
    );
}

def budget -> RunBudget {
    return RunBudget(limits={"sec_data": 20, "sec_archives": 20});
}

def aapl_filings -> list[Filing] {
    return filings("AAPL", AAPL, budget(), client("sec_data"))[1];
}

def fetched -> Fetched {
    return Fetched(source="sec_data", dataset="sec.companyfacts", source_url="https://data.sec.gov/x", fetched_at="2026-10-15T00:00:00+00:00", body="", from_cache=False);
}

"""The figure `name`, which the test expects to be present."""
def figure(funda: Fundamentals | None, name: str) -> ReportedValue {
    assert funda is not None;
    found = funda.get(name);
    assert found is not None, f"no {name}";
    return found;
}

def row(start: str, end: str, val: float, filed: str, accn: str = "0000000001-26-000001") -> dict[str, object] {
    found: dict[str, object] = {"end": end, "val": val, "filed": filed, "accn": accn, "form": "10-Q"};
    if start {
        found["start"] = start;
    }
    return found;
}

def usd(concept: str, rows: list[dict[str, object]]) -> dict[str, dict] {
    return {concept: {"units": {"USD": rows}}};
}

test "tickers map to padded CIKs, written as Alpaca writes share classes" {
    fake.reset();
    ciks = cik_map(budget(), client("sec_archives"));
    assert fake.misses == [];
    assert ciks["AAPL"] == AAPL;
    assert ciks["BRK.B"] == "0001067983" and "BRK-B" not in ciks;
    assert ciks["GOOG"] == ciks["GOOGL"];
    assert fake.requests[0].headers["User-Agent"] == AGENT;
    assert padded_cik(320193) == AAPL;
}

test "the filing index is newest first, with 8-K items in words and index-page citations" {
    fake.reset();
    (name, found) = filings("AAPL", AAPL, budget(), client("sec_data"));
    assert fake.misses == [];
    assert name == "Apple Inc." and len(found) == 80;
    assert (found[0].form, found[0].filed, found[0].accession) == ("4", "2026-10-08", "0001140361-26-039158");
    assert found[0].stamp.source_url == "https://www.sec.gov/Archives/edgar/data/320193/000114036126039158/0001140361-26-039158-index.htm";
    assert found[0].stamp.published_at == "2026-10-08";
    events = eight_ks(found, "2026-04-01");
    assert [(f.filed, f.items) for f in events] == [
        ("2026-09-01", ["5.02"]), ("2026-07-30", ["2.02", "9.01"]), ("2026-04-30", ["2.02", "9.01"]), ("2026-04-20", ["5.02"])
    ];
    assert events[0].item_names() == ["director or officer change"];
    assert events[1].item_names() == ["results of operations (earnings)", "financial statements and exhibits"];
}

test "company facts reduce to the latest quarter, trailing twelve months, and the balance sheet" {
    fake.reset();
    (funda, gaps) = fundamentals("AAPL", AAPL, budget(), client("sec_data"));
    assert fake.misses == [] and gaps == [];
    assert funda is not None;
    assert funda.company == "Apple Inc.";
    revenue = figure(funda, "revenue_quarter");
    assert revenue.value == 109417000000.0;
    assert revenue.period == "quarter 2026-03-29 to 2026-06-27";
    assert revenue.source_url == "https://www.sec.gov/Archives/edgar/data/320193/000032019326000020/0000320193-26-000020-index.htm";
    # The press release says revenue was "up 16 percent year over year".
    assert round(figure(funda, "revenue_growth_yoy").value, 3) == 0.164;
    # Q4 FY2025 plus the first three quarters of FY2026.
    assert figure(funda, "revenue_ttm").value == 466823000000.0;
    # Cash flows are year to date in a 10-Q: FY2025 + 9 months of FY2026 - 9 months of FY2025.
    assert figure(funda, "operating_cash_flow_ttm").value == 146724000000.0;
    assert figure(funda, "free_cash_flow_ttm").value == 146724000000.0 - 10041000000.0;
    assert figure(funda, "eps_diluted_quarter").value == 2.02 and figure(funda, "eps_diluted_quarter_prior_year").value == 1.57;
    assert figure(funda, "long_term_debt").value == 71340000000.0;
    assert round(figure(funda, "gross_margin_ttm").value, 3) == 0.487;
    assert figure(funda, "shares_outstanding").period == "as of 2026-07-17";
    assert funda.stamp.published_at == "2026-07-31";
}

test "a concept the filer switched to wins over the one it stopped using" {
    facts = {
        "us-gaap": usd("Revenues", [row("2019-01-01", "2019-03-31", 50.0, "2019-05-01")])
        | usd("RevenueFromContractWithCustomerExcludingAssessedTax", [row("2026-01-01", "2026-03-31", 80.0, "2026-05-01")])
    };
    (funda, _) = reduce_facts("X", "1", "X", facts, fetched());
    assert figure(funda, "revenue_quarter").value == 80.0;
}

test "a restated period uses the newest filing, and a smaller loss is growth" {
    facts = {
        "us-gaap": usd(
            "NetIncomeLoss",
            [
                row("2025-01-01", "2025-03-31", -40.0, "2025-05-01"),
                row("2025-01-01", "2025-03-31", -50.0, "2026-05-01"),
                row("2026-01-01", "2026-03-31", -25.0, "2026-05-01")
            ]
        )
    };
    (funda, gaps) = reduce_facts("X", "1", "X", facts, fetched());
    assert funda is not None;
    assert figure(funda, "net_income_growth_yoy").value == 0.5;
    assert "sec.companyfacts: X reports no revenue" in gaps;
    assert funda.get("net_income_ttm") is None;
}

test "a company with no usable facts is a gap, not a report" {
    (funda, gaps) = reduce_facts("X", "1", "X", {"us-gaap": {}}, fetched());
    assert funda is None;
    assert gaps[-1] == "sec.companyfacts: X has no usable XBRL facts";
}

test "Form 4 trades carry the insider, the code, the plan flag, and the filing lag" {
    found = aapl_filings();
    fake.reset();
    (trades, gaps) = insider_trades("AAPL", found, "2026-09-25", budget(), client("sec_archives"), limit=4);
    assert fake.misses == [];
    assert len(fake.requests) == 4;
    assert gaps == ["sec.filing: only the newest 4 Form 4 filings for AAPL since 2026-09-25 were read"];
    sale = trades[0];
    assert (sale.insider, sale.role, sale.day, sale.code, sale.acquired) == ("Newstead Jennifer", "SVP, GC and Government Affairs", "2026-10-06", "S", False);
    assert (sale.shares, sale.price, sale.shares_after) == (2399.0, 332.01, 39593.0);
    assert sale.planned and sale.filing_lag_days == 2;
    assert round(sale.value() or 0.0) == round(2399 * 332.01);
    assert sale.stamp.source_url == "https://www.sec.gov/Archives/edgar/data/320193/000114036126039158/0001140361-26-039158-index.htm";
    assert {t.code for t in trades} == {"S", "M", "F", "G"};
    assert [t.role for t in trades if t.insider == "COOK TIMOTHY D"][0] == "Executive Chair, director";
}

test "the newest Item 2.02 release is read from its EX-99.1 exhibit, without EDGAR's headers" {
    found = aapl_filings();
    fake.reset();
    release = earnings_release("AAPL", found, "2026-07-15", budget(), client("sec_archives"));
    assert fake.misses == [];
    assert release is not None;
    assert release.exhibit_url == "https://www.sec.gov/Archives/edgar/data/320193/000032019326000018/a8-kex991q3202606272026.htm";
    assert release.text.startswith("Exhibit 99.1\n\nApple reports third quarter results");
    assert "quarterly revenue of $109.4 billion, up 16 percent" in release.text;
    assert len(release.text) <= 6000;
    assert release.as_untrusted().startswith('<untrusted-data kind="earnings press release (8-K exhibit 99)" filed="2026-07-30"');
    assert earnings_release("AAPL", found, "2026-08-01", budget(), client("sec_archives")) is None;
}

test "an index without an EX-99 exhibit has no release path" {
    page = '<table class="tableFile"><tr><td>1</td><td>8-K</td><td><a href="/Archives/x/a.htm">a.htm</a></td><td>8-K</td></tr></table>';
    assert exhibit_path(page) == "";
    linked = page.replace("<td>8-K</td></tr>", "<td>EX-99.1</td></tr>").replace("/Archives/x/a.htm", "/ix?doc=/Archives/x/b.htm");
    assert exhibit_path(linked) == "/Archives/x/b.htm";
    assert document_html("<p>plain</p>") == "<p>plain</p>";
}

test "SEC's refusal of an undeclared tool is raised without retrying" {
    data = client("sec_data");
    fake.reset();
    fake.script = [(403, {}, "Your Request Originates from an Undeclared Automated Tool")];
    with testraises(SourceError, `match="status 403") {
        filings("MSFT", "789019", budget(), data);
    }
    assert len(fake.requests) == 1;
}

test "a User-Agent without a real contact email is refused before any request" {
    saved = os.environ.pop("SEC_USER_AGENT", None);
    try {
        with testraises(MissingKey, `match="SEC_USER_AGENT is not set") {
            sec_user_agent();
        }
        os.environ["SEC_USER_AGENT"] = "trading-agent team-contact@example.com";
        with testraises(MissingKey, `match="needs a real contact email") {
            sec_user_agent();
        }
        os.environ["SEC_USER_AGENT"] = AGENT;
        assert sec_user_agent() == AGENT;
    } finally {
        if saved is not None {
            os.environ["SEC_USER_AGENT"] = saved;
        } else {
            del os.environ["SEC_USER_AGENT"];
        }
    }
}
