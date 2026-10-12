"""The Wikipedia collector against recorded pages: constituents, dated index changes, and
point-in-time membership. No network."""
import json;
import tempfile;
import from pathlib { Path }
import from jaclang.data.storage.storage { Storage }
import from models.research { Stamp }
import from research.collector {
    RawCache,
    RunBudget,
    SourceClient,
    TokenBucket,
    UnexpectedResponse
}
import from research.sources { SOURCES }
import from research.wikipedia {
    Constituent,
    IndexChange,
    USER_AGENT,
    alpaca_symbol,
    constituents,
    index_changes,
    members_on,
    table_records
}
import from tests.fakes.source_server { FakeSource, serve_source }

glob FIXTURES: Path = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "wikipedia";
glob fake: FakeSource = serve_source(SOURCES["wikipedia"].base_url_env, FIXTURES);
glob LIST_BODY: str = json.loads(next(FIXTURES.glob("wikipedia.constituents-*.json")).read_text())["body"];

def client(cache: RawCache | None = None) -> SourceClient {
    fake.reset();
    return SourceClient(
        source=SOURCES["wikipedia"],
        headers={"User-Agent": USER_AGENT},
        cache=cache or RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage),
        bucket=TokenBucket(per_minute=60000, burst=100),
        backoff_s=0.0
    );
}

def budget -> RunBudget {
    return RunBudget(limits={"wikipedia": 10});
}

def stamp -> Stamp {
    return Stamp(source="wikipedia", dataset="test", source_url="", published_at="", fetched_at="");
}

def member(symbol: str) -> Constituent {
    return Constituent(symbol=symbol, name=symbol, sector="", sub_industry="", cik="", date_added="", stamp=stamp());
}

def change(effective: str, added: str, removed: str) -> IndexChange {
    return IndexChange(effective=effective, added=added, added_name="", removed=removed, removed_name="", reason="", stamp=stamp());
}

test "the constituents table is read with sectors, CIKs, and Alpaca tickers" {
    current = constituents(budget(), client());
    assert fake.misses == [];
    assert len(current) == 503;
    assert len({c.symbol for c in current}) == 503;
    mmm = current[0];
    assert (mmm.symbol, mmm.name, mmm.sector, mmm.sub_industry, mmm.cik, mmm.date_added) == ("MMM", "3M", "Industrials", "Industrial Conglomerates", "0000066740", "1957-03-04");
    symbols = {c.symbol for c in current};
    assert {"BRK.B", "BF.B"} <= symbols;
    assert len({c.sector for c in current}) == 11;
    # A footnote marker in a cell is dropped.
    noc = [c for c in current if c.symbol == "NOC"][0];
    assert noc.cik == "0001133421";
    # Every member cites the exact revision it was read from.
    assert mmm.stamp.source_url == "https://en.wikipedia.org/w/index.php?title=List_of_S%26P_500_companies&oldid=1379247819";
    assert mmm.stamp.dataset == "wikipedia.constituents";
    assert mmm.stamp.published_at == mmm.stamp.fetched_at;
    assert fake.requests[0].headers["User-Agent"] == USER_AGENT;
}

test "the constituents list is fetched once a week" {
    shared = client();
    spent = budget();
    constituents(spent, shared);
    constituents(spent, shared);
    assert len(fake.requests) == 1;
    assert spent.spent == {"wikipedia": 1};
}

test "index changes are read newest first with clean tickers" {
    (changes, gaps) = index_changes(budget(), client());
    assert gaps == [];
    assert len(changes) == 412;
    assert [c.effective for c in changes] == sorted([c.effective for c in changes], reverse=True);
    first = changes[0];
    assert (first.effective, first.added, first.removed) == ("2026-10-06", "TWLO", "WBD");
    assert first.added_name == "Twilio" and first.removed_name == "Warner Bros. Discovery";
    # A spin-off adds with nothing removed.
    vylor = [c for c in changes if c.added == "VYLR"][0];
    assert vylor.removed == "" and "spin-off" in vylor.reason;
    # "ALLE |" in the page is the ticker ALLE.
    assert [c.removed for c in changes if c.added == "ALLE"] == ["JCP"];
    # A row missing its last cell still parses.
    assert [c.reason for c in changes if c.added == "ARNC"][0].startswith("Alcoa completed");
    assert "Historical_components_of_the_S%26P_500&oldid=" in first.stamp.source_url;
}

test "membership on a past day undoes every later change" {
    shared = client();
    current = constituents(budget(), shared);
    (changes, _) = index_changes(budget(), shared);
    today = members_on("2026-10-08", current, changes);
    assert today.symbols == sorted(c.symbol for c in current) and today.gaps == [];
    # A change counts from its effective date.
    on_change = members_on("2026-10-06", current, changes);
    assert "TWLO" in on_change.symbols and "WBD" not in on_change.symbols;
    before = members_on("2026-10-05", current, changes);
    assert {"WBD", "CTVA"} <= set(before.symbols) and "TWLO" not in before.symbols;
    # Ten years back the index still has about 500 lines, and renames are named as gaps.
    old = members_on("2016-01-04", current, changes);
    assert 495 <= len(old.symbols) <= 515;
    assert any(g.startswith("FLT was added on 2018-06-20") for g in old.gaps);
}

test "changes that cannot be undone are named, not guessed" {
    current = [member("NEW"), member("KEPT")];
    result = members_on(
        "2020-01-01",
        current,
        [change("2021-01-01", "NEW", "OLD"), change("2022-01-01", "GONE", ""), change("2023-01-01", "", "KEPT")]
    );
    assert result.symbols == ["KEPT", "OLD"];
    assert len(result.gaps) == 2;
    assert "GONE was added on 2022-01-01" in result.gaps[1];
    assert "KEPT was removed on 2023-01-01" in result.gaps[0];
}

test "an API error answered with status 200 is not cached" {
    cache = RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage);
    shared = client(cache);
    fake.script = [(200, {}, '{"error": {"code": "maxlag", "info": "Waiting for a database server"}}')];
    with testraises(UnexpectedResponse) as raised {
        constituents(budget(), shared);
    }
    assert "without a page" in str(raised.value);
    assert len(constituents(budget(), shared)) == 503;
}

test "a cut-short constituents table is refused" {
    parsed = json.loads(LIST_BODY);
    text = parsed["parse"]["text"];
    parsed["parse"]["text"] = text[:text.find("<tr", 20000)] + "</tbody></table>";
    fake.reset();
    shared = client();
    fake.script = [(200, {}, json.dumps(parsed))];
    with testraises(UnexpectedResponse) as raised {
        constituents(budget(), shared);
    }
    assert "outside 480-520" in str(raised.value);
}

test "tables are read with spanning cells, grouped headers, and footnotes" {
    page = """
    <table id="other"><tr><th>Wrong</th></tr></table>
    <table id="t">
      <tr><th rowspan="2">Date</th><th colspan="2">Added</th><th rowspan="2">Note</th></tr>
      <tr><th>Ticker</th><th>Name</th></tr>
      <tr><td rowspan="2">May 1</td><td>AAA<sup class="reference"><a>[1]</a></sup></td><td>A<br>Co</td><td>x &amp; y</td></tr>
      <tr><td>BBB</td><td><table><tr><td>nested</td></tr></table>B Co</td></tr>
    </table>""";
    rows = table_records(page, "t");
    assert rows == [
        {"Date": "May 1", "Added Ticker": "AAA", "Added Name": "A Co", "Note": "x & y"},
        {"Date": "May 1", "Added Ticker": "BBB", "Added Name": "B Co", "Note": ""}
    ];
    with testraises(ValueError) {
        table_records(page, "missing");
    }
}

test "tickers are written the way Alpaca writes them" {
    assert alpaca_symbol("brk-b") == "BRK.B";
    assert alpaca_symbol("BF/B") == "BF.B";
    assert alpaca_symbol("ALLE |") == "ALLE";
    assert alpaca_symbol(" ") == "";
}
