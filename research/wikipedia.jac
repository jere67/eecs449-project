"""S&P 500 constituents and point-in-time membership from Wikipedia (TDD §5, step 1).

The current members, with GICS sector and sub-industry, come from the constituents table of
"List of S&P 500 companies". The dated additions and removals in "Historical components of
the S&P 500" rebuild membership on any past day, so the backtest harness trades the index
as it was then and has no survivorship bias.

Both pages are read through the MediaWiki parse API, which returns the rendered HTML and
the revision it came from; each datum cites that revision's permanent link. The pages are
community-maintained, so the harness spot-checks them against S&P's announcements.
"""
import json;
import re;
import from datetime { date, datetime }
import from html.parser { HTMLParser }
import from urllib.parse { quote }
import httpx;
import from models.research { Stamped }
import from research.collector { Fetched, RunBudget, SourceClient }
import from research.sources { DATASETS, Dataset, SOURCES }

glob LIST_PAGE: str = "List_of_S&P_500_companies";
glob CHANGES_PAGE: str = "Historical_components_of_the_S&P_500";

# Wikimedia asks every client to name itself and give a contact (its User-Agent policy).
glob USER_AGENT: str = f"trading-agent/0.1 (https://github.com/jere67/eecs449-project) httpx/{httpx.__version__}";

# The index has about 503 lines (some companies list two share classes); outside these
# bounds the table was cut or its layout changed, and the list must not reach the screener.
glob MIN_CONSTITUENTS: int = 480;
glob MAX_CONSTITUENTS: int = 520;

glob _TICKER: re.Pattern[str] = re.compile(r"[A-Z][A-Z0-9]*(?:[.\-/][A-Z0-9]+)?");

"""One current member of the index."""
obj Constituent(Stamped) {
    has symbol: str,
        name: str,
        sector: str,
        sub_industry: str,
        cik: str,
        date_added: str;
}

"""One dated change to the index. Either side may be empty, as for a spin-off."""
obj IndexChange(Stamped) {
    has effective: str,
        added: str,
        added_name: str,
        removed: str,
        removed_name: str,
        reason: str;
}

"""The index's members on one day, and what could not be reconstructed exactly."""
obj Membership {
    has day: str,
        symbols: list[str],
        gaps: list[str];
}

"""A ticker as Alpaca writes it: upper case, with a dot before a share class (BRK.B, not
BRK-B or BRK/B). Returns "" when the text holds no ticker."""
def alpaca_symbol(text: str) -> str {
    found = _TICKER.search(text.strip().upper());
    return re.sub(r"[\-/]", ".", found.group(0)) if found else "";
}

def wikipedia_client -> SourceClient {
    return SourceClient(source=SOURCES["wikipedia"], headers={"User-Agent": USER_AGENT});
}

"""The current members, from the weekly-cached constituents table."""
def constituents(budget: RunBudget, client: SourceClient | None = None) -> list[Constituent] {
    (fetched, rows) = _table(client or wikipedia_client(), DATASETS["wikipedia.constituents"], LIST_PAGE, "constituents", _check_constituents, budget);
    page = _permalink(fetched);
    return [
        Constituent(
            symbol=alpaca_symbol(row["Symbol"]),
            name=row["Security"],
            sector=row["GICS Sector"],
            sub_industry=row["GICS Sub-Industry"],
            cik=row["CIK"],
            date_added=row["Date added"],
            stamp=fetched.stamp(fetched.fetched_at, source_url=page)
        )
        for row in rows
    ];
}

"""Every dated change to the index, newest first, and a gap for each row without a
readable date."""
def index_changes(budget: RunBudget, client: SourceClient | None = None) -> tuple[list[IndexChange], list[str]] {
    (fetched, rows) = _table(client or wikipedia_client(), DATASETS["wikipedia.history"], CHANGES_PAGE, "changes", _check_changes, budget);
    page = _permalink(fetched);
    changes: list[IndexChange] = [];
    gaps: list[str] = [];
    for row in rows {
        effective = _change_date(row["Effective Date"]);
        if effective is None {
            gaps.append(
                f"wikipedia.history: a change has no readable date ({row['Effective Date']!r}), so it was excluded ({page})"
            );
            continue;
        }
        changes.append(
            IndexChange(
                effective=effective,
                added=alpaca_symbol(row["Added Ticker"]),
                added_name=row["Added Security"],
                removed=alpaca_symbol(row["Removed Ticker"]),
                removed_name=row["Removed Security"],
                reason=row["Reason"],
                stamp=fetched.stamp(fetched.fetched_at, source_url=page)
            )
        );
    }
    changes.sort(key=lambda (c: IndexChange) { c.effective; }, reverse=True);
    return (changes, gaps);
}

"""The members on `day` (ISO date): today's list with every later change undone.

A change takes effect on its effective date, so it is undone only for earlier days. A
change that cannot be undone is named in the gaps instead of guessed at; most are ticker
changes the table does not record, such as FB to META.
"""
def members_on(day: str, current: list[Constituent], changes: list[IndexChange]) -> Membership {
    symbols = {c.symbol for c in current};
    gaps: list[str] = [];
    for change in sorted(changes, key=lambda (c: IndexChange) { c.effective; }, reverse=True) {
        if change.effective <= day {
            break;
        }
        if change.added {
            if change.added in symbols {
                symbols.remove(change.added);
            } else {
                gaps.append(
                    f"{change.added} was added on {change.effective} but is not a member after it, so its earlier ticker is unknown"
                );
            }
        }
        if change.removed {
            if change.removed in symbols {
                gaps.append(
                    f"{change.removed} was removed on {change.effective} but is still a member after it, so the row may be wrong"
                );
            } else {
                symbols.add(change.removed);
            }
        }
    }
    return Membership(day=day, symbols=sorted(symbols), gaps=gaps);
}

"""Fetch a page's rendered HTML and read the table with `table_id` into rows keyed by header."""
def _table(
    client: SourceClient,
    dataset: Dataset,
    title: str,
    table_id: str,
    check: Callable[[list[dict[str, str]]], str],
    budget: RunBudget
) -> tuple[Fetched, list[dict[str, str]]] {
    def check_body(body: str) -> str {
        try {
            return check(_rows(body, table_id));
        } except (ValueError, KeyError, TypeError) as e {
            return f"{title}: {e}";
        }
    }
    fetched = client.get(
        dataset,
        "/w/api.php",
        budget,
        params={
            "action": "parse",
            "page": title,
            "prop": "text|revid",
            "formatversion": 2,
            "format": "json",
            "redirects": 1
        },
        symbol=table_id,
        check=check_body
    );
    return (fetched, _rows(fetched.body, table_id));
}

def _rows(body: str, table_id: str) -> list[dict[str, str]] {
    parsed = json.loads(body);
    if "parse" not in parsed {
        raise ValueError(f"the API answered without a page: {body[:200]}");
    }
    return table_records(parsed["parse"]["text"], table_id);
}

def _check_constituents(rows: list[dict[str, str]]) -> str {
    for column in ["Symbol", "Security", "GICS Sector", "GICS Sub-Industry", "Date added", "CIK"] {
        if rows and column not in rows[0] {
            return f"the constituents table has no {column!r} column";
        }
    }
    if not MIN_CONSTITUENTS <= len(rows) <= MAX_CONSTITUENTS {
        return f"the constituents table has {len(rows)} rows, outside {MIN_CONSTITUENTS}-{MAX_CONSTITUENTS}";
    }
    missing = [r["Security"] for r in rows if not alpaca_symbol(r["Symbol"])];
    return f"constituents without a ticker: {missing}" if missing else "";
}

def _check_changes(rows: list[dict[str, str]]) -> str {
    if not rows {
        return "the changes table is empty";
    }
    for column in ["Effective Date", "Added Ticker", "Added Security", "Removed Ticker", "Removed Security", "Reason"] {
        if column not in rows[0] {
            return f"the changes table has no {column!r} column";
        }
    }
    return "";
}

"""An ISO date from the table's "October 6, 2026", or None."""
def _change_date(text: str) -> str | None {
    try {
        return datetime.strptime(text.strip(), "%B %d, %Y").date().isoformat();
    } except ValueError {
        return None;
    }
}

"""The permanent link to the revision a response came from, for citations."""
def _permalink(fetched: Fetched) -> str {
    parsed = json.loads(fetched.body)["parse"];
    title = quote(parsed["title"].replace(" ", "_"), safe="_");
    return f"https://en.wikipedia.org/w/index.php?title={title}&oldid={parsed['revid']}";
}

"""The rows of the HTML table with `table_id`, keyed by column header.

Spanning cells are copied into every row and column they cover. A column under a grouped
header is named by both, such as "Added Ticker". Footnote markers are dropped, and a row
with fewer cells than headers gets "" for the rest.
"""
def table_records(html: str, table_id: str) -> list[dict[str, str]] {
    parser = _TableParser(table_id);
    parser.feed(html);
    parser.close();
    if not parser.found {
        raise ValueError(f"no table with id {table_id!r}");
    }
    grid = _expand(parser.rows);
    heads = 0;
    while heads < len(grid) and grid[heads] and all(header for (header, _) in grid[heads]) {
        heads += 1;
    }
    if heads == 0 {
        raise ValueError(f"table {table_id!r} has no header row");
    }
    width = max(len(row) for row in grid[:heads]);
    labels: list[str] = [];
    for col in range(width) {
        parts: list[str] = [];
        for row in grid[:heads] {
            text = row[col][1] if col < len(row) else "";
            if text and text not in parts {
                parts.append(text);
            }
        }
        labels.append(" ".join(parts));
    }
    return [
        {label: (row[col][1] if col < len(row) else "") for (col, label) in enumerate(labels)}
        for row in grid[heads:]
        if row
    ];
}

"""Lay out cells as (is_header, text) on a grid, copying each spanning cell into every
position it covers."""
def _expand(rows: list[list[tuple[bool, str, int, int]]]) -> list[list[tuple[bool, str]]] {
    grid: list[list[tuple[bool, str]]] = [];
    # Column -> (rows still to fill, cell) for cells spanning down from earlier rows.
    pending: dict[int, tuple[int, tuple[bool, str]]] = {};
    for cells in rows {
        out: list[tuple[bool, str]] = [];
        queue = list(cells);
        col = 0;
        while queue or any(c >= col for c in pending) {
            if col in pending {
                (left, cell) = pending[col];
                out.append(cell);
                if left > 1 {
                    pending[col] = (left - 1, cell);
                } else {
                    del pending[col];
                }
                col += 1;
                continue;
            }
            if not queue {
                break;
            }
            (header, text, rowspan, colspan) = queue.pop(0);
            for _ in range(colspan) {
                out.append((header, text));
                if rowspan > 1 {
                    pending[col] = (rowspan - 1, (header, text));
                }
                col += 1;
            }
        }
        grid.append(out);
    }
    return grid;
}

"""Collects the cells of one table as (is_header, text, rowspan, colspan), ignoring nested
tables and footnote markers."""
class _TableParser(HTMLParser) {
    def init(self: _TableParser, table_id: str) {
        super.init(convert_charrefs=True);
        self.table_id = table_id;
        self.found = False;
        self.rows: list[list[tuple[bool, str, int, int]]] = [];
        # Table nesting depth inside ours: 0 is outside it, 1 is in it.
        self._depth = 0;
        self._cell: list[str] | None = None;
        self._cell_info: tuple[bool, int, int] = (False, 1, 1);
        # The tag being skipped (a footnote marker, style, or script) and its nesting.
        self._skip_tag = "";
        self._skip = 0;
    }

    override def handle_starttag(self: _TableParser, tag: str, attrs: list[tuple[str, str | None]]) {
        found = dict(attrs);
        if tag == "table" {
            if self._depth {
                self._depth += 1;
            } elif found.get("id") == self.table_id and not self.found {
                self.found = True;
                self._depth = 1;
            }
            return;
        }
        if self._depth != 1 {
            return;
        }
        if self._skip_tag {
            if tag == self._skip_tag {
                self._skip += 1;
            }
        } elif (tag == "sup" and "reference" in (found.get("class") or "")) or tag in ("style", "script") {
            self._skip_tag = tag;
            self._skip = 1;
        } elif tag == "tr" {
            self._end_cell();
            self.rows.append([]);
        } elif tag in ("td", "th") {
            self._end_cell();
            if not self.rows {
                self.rows.append([]);
            }
            self._cell = [];
            self._cell_info = (tag == "th", _span(found.get("rowspan")), _span(found.get("colspan")));
        } elif tag == "br" and self._cell is not None {
            self._cell.append(" ");
        }
    }

    override def handle_endtag(self: _TableParser, tag: str) {
        if tag == "table" and self._depth {
            self._depth -= 1;
            if self._depth == 0 {
                self._end_cell();
            }
            return;
        }
        if self._depth != 1 {
            return;
        }
        if self._skip_tag {
            if tag == self._skip_tag {
                self._skip -= 1;
                if self._skip == 0 {
                    self._skip_tag = "";
                }
            }
        } elif tag in ("td", "th", "tr") {
            self._end_cell();
        }
    }

    override def handle_data(self: _TableParser, data: str) {
        if self._depth == 1 and not self._skip_tag and self._cell is not None {
            self._cell.append(data);
        }
    }

    def _end_cell(self: _TableParser) {
        if self._cell is None {
            return;
        }
        text = " ".join("".join(self._cell).split());
        (header, rowspan, colspan) = self._cell_info;
        self.rows[-1].append((header, text, rowspan, colspan));
        self._cell = None;
    }
}

def _span(value: str | None) -> int {
    try {
        return max(1, int(value or "1"));
    } except ValueError {
        return 1;
    }
}
