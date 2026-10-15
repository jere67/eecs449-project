"""SEC EDGAR (TDD §6, §7): the ticker-to-CIK map, each company's filing index, XBRL company
facts reduced to key fundamentals, 8-K events with Item 2.02 earnings releases, and Form 4
insider trades stamped with their filing lag.

SEC fair access asks for a User-Agent naming the requester and a contact email, and under 10
requests a second across sec.gov (https://www.sec.gov/os/accessing-edgar-data); both hosts
share one rate limiter (research/sources.jac). No key is needed, so the User-Agent from
SEC_USER_AGENT is required instead, and the .env.example placeholder is refused.

Institutional holdings (13F) are out of scope: they live in each manager's filing, with no
per-issuer endpoint, so a per-stock view needs SEC's quarterly bulk data sets (#22).

Filing text is untrusted (TDD §14): an earnings release is reduced to plain text, capped,
and handed to an agent only through `EarningsRelease.as_untrusted`.
"""
import json;
import re;
import xml.etree.ElementTree as ET;
import from datetime { date }
import from models.research { Stamped }
import from research.collector {
    Fetched,
    MissingKey,
    RunBudget,
    SourceClient,
    SourceError,
    env_key
}
import from research.sources { DATASETS, SOURCES }
import from research.text { cap, html_to_text, untrusted_block }
import from research.wikipedia { alpaca_symbol }

glob ARCHIVES: str = "https://www.sec.gov";
glob MAX_RELEASE_CHARS: int = 6000;
# A quarter is 13 weeks (91 days), give or take a 53-week year; a fiscal year is 52 or 53 weeks.
glob QUARTER_DAYS: tuple[int, int] = (80, 100);
glob YEAR_DAYS: tuple[int, int] = (350, 380);
glob PERIOD_SLACK_DAYS: int = 10;

# What each 8-K item reports (https://www.sec.gov/files/form8-k.pdf).
glob EIGHT_K_ITEMS: dict[str, str] = {
    "1.01": "entry into a material agreement",
    "1.02": "termination of a material agreement",
    "1.03": "bankruptcy or receivership",
    "1.05": "material cybersecurity incident",
    "2.01": "completed acquisition or disposition",
    "2.02": "results of operations (earnings)",
    "2.03": "new material debt obligation",
    "2.05": "exit or restructuring costs",
    "2.06": "material impairment",
    "3.01": "delisting or listing-rule notice",
    "3.02": "unregistered sale of equity",
    "4.01": "change of auditor",
    "4.02": "prior financial statements no longer reliable",
    "5.01": "change in control",
    "5.02": "director or officer change",
    "5.03": "charter or bylaw amendment",
    "5.07": "shareholder vote results",
    "7.01": "Regulation FD disclosure",
    "8.01": "other events",
    "9.01": "financial statements and exhibits"
};

# Form 4 transaction codes (https://www.sec.gov/about/forms/form4data.pdf). P and S are the
# open-market trades that carry a signal; the rest are mostly compensation.
glob TRANSACTION_CODES: dict[str, str] = {
    "P": "open-market purchase",
    "S": "open-market sale",
    "A": "grant or award",
    "M": "option exercise",
    "F": "shares withheld for tax",
    "G": "gift",
    "D": "disposition to the issuer",
    "C": "conversion",
    "X": "option exercise",
    "J": "other"
};

"""One company's filing, cited by its EDGAR index page."""
obj Filing(Stamped) {
    has symbol: str,
        cik: str,
        form: str,
        accession: str,
        filed: str,
        report_date: str,
        accepted_at: str,
        items: list[str],
        primary_document: str;

    def folder -> str {
        return f"/Archives/edgar/data/{int(self.cik)}/{self.accession.replace('-', '')}";
    }

    def index_url -> str {
        return _filing_index(self.cik, self.accession);
    }

    """The 8-K items as words, such as "director or officer change"."""
    def item_names -> list[str] {
        return [EIGHT_K_ITEMS.get(i, f"item {i}") for i in self.items];
    }
}

"""One reported or derived figure, with the period it covers and the filing it came from."""
obj ReportedValue {
    has name: str,
        value: float,
        unit: str,
        period: str,
        filed: str,
        source_url: str;
}

"""Key fundamentals from XBRL company facts, published as of the newest filing they use."""
obj Fundamentals(Stamped) {
    has symbol: str,
        cik: str,
        company: str,
        values: list[ReportedValue];

    def get(name: str) -> ReportedValue | None {
        for v in self.values {
            if v.name == name {
                return v;
            }
        }
        return None;
    }
}

"""A Form 4 transaction in common stock. `filing_lag_days` is days from trade to filing."""
obj InsiderTrade(Stamped) {
    has symbol: str,
        insider: str,
        role: str,
        day: str,
        code: str,
        acquired: bool,
        shares: float,
        price: float | None,
        shares_after: float | None,
        planned: bool,
        filed: str,
        filing_lag_days: int;

    def value -> float | None {
        return self.shares * self.price if self.price is not None else None;
    }
}

"""The text of an 8-K's earnings press release (Item 2.02, exhibit 99)."""
obj EarningsRelease(Stamped) {
    has symbol: str,
        accession: str,
        filed: str,
        exhibit_url: str,
        text: str;

    def as_untrusted -> str {
        return untrusted_block(
            "earnings press release (8-K exhibit 99)",
            self.text,
            {"filed": self.filed, "url": self.exhibit_url}
        );
    }
}

"""The SEC_USER_AGENT value, refusing an unset one or the template's placeholder."""
def sec_user_agent -> str {
    agent = env_key("sec", "SEC_USER_AGENT");
    if "@" not in agent or "example.com" in agent {
        raise MissingKey(source="sec", url="", detail="SEC_USER_AGENT needs a real contact email; see .env.example");
    }
    return agent;
}

def sec_data_client -> SourceClient {
    return SourceClient(source=SOURCES["sec_data"], headers={"User-Agent": sec_user_agent()});
}

def sec_archives_client -> SourceClient {
    return SourceClient(source=SOURCES["sec_archives"], headers={"User-Agent": sec_user_agent()});
}

"""A CIK as EDGAR's paths and file names write it: ten digits, zero-padded."""
def padded_cik(cik: str | int) -> str {
    return str(int(cik)).zfill(10);
}

"""Every ticker SEC lists, written as Alpaca writes it (BRK.B), mapped to its padded CIK."""
def cik_map(budget: RunBudget, client: SourceClient | None = None) -> dict[str, str] {
    fetched = (client or sec_archives_client()).get(
        DATASETS["sec.tickers"], "/files/company_tickers.json", budget, check=_check_tickers
    );
    return {
        alpaca_symbol(str(row["ticker"])): padded_cik(row["cik_str"])
        for row in json.loads(fetched.body).values()
    };
}

"""The company's recent filings, newest first, from its submissions file, and its name."""
def filings(symbol: str, cik: str, budget: RunBudget, client: SourceClient | None = None) -> tuple[str, list[Filing]] {
    padded = padded_cik(cik);
    fetched = (client or sec_data_client()).get(
        DATASETS["sec.submissions"],
        f"/submissions/CIK{padded}.json",
        budget,
        symbol=symbol,
        check=_check_keys("filings", "name")
    );
    parsed = json.loads(fetched.body);
    recent: dict[str, list[str]] = parsed["filings"]["recent"];
    found: list[Filing] = [];
    for i in range(len(recent["accessionNumber"])) {
        accession = recent["accessionNumber"][i];
        found.append(Filing(
            symbol=symbol,
            cik=padded,
            form=recent["form"][i],
            accession=accession,
            filed=recent["filingDate"][i],
            report_date=recent["reportDate"][i] or "",
            accepted_at=recent["acceptanceDateTime"][i] or "",
            items=[item.strip() for item in (recent["items"][i] or "").split(",") if item.strip()],
            primary_document=recent["primaryDocument"][i] or "",
            stamp=fetched.stamp(recent["filingDate"][i], source_url=_filing_index(padded, accession))
        ));
    }
    found.sort(key=lambda (f: Filing) { f.accepted_at or f.filed; }, reverse=True);
    return (str(parsed.get("name") or ""), found);
}

"""8-K filings from `since` (ISO date) on, newest first."""
def eight_ks(found: list[Filing], since: str) -> list[Filing] {
    return [f for f in found if f.form in ("8-K", "8-K/A") and f.filed >= since];
}

"""Key fundamentals from the company's XBRL facts, and a gap for each one it does not report."""
def fundamentals(symbol: str, cik: str, budget: RunBudget, client: SourceClient | None = None) -> tuple[Fundamentals | None, list[str]] {
    padded = padded_cik(cik);
    fetched = (client or sec_data_client()).get(
        DATASETS["sec.companyfacts"],
        f"/api/xbrl/companyfacts/CIK{padded}.json",
        budget,
        symbol=symbol,
        check=_check_keys("facts")
    );
    parsed = json.loads(fetched.body);
    return reduce_facts(symbol, padded, str(parsed.get("entityName") or ""), parsed["facts"], fetched);
}

"""A reported fact for one period, from the newest filing that reports it."""
obj Fact {
    has concept: str,
        unit: str,
        start: str,
        end: str,
        value: float,
        form: str,
        filed: str,
        accession: str;

    def days -> int {
        return _days(self.start, self.end) if self.start else 0;
    }
}

# Each figure lists the us-gaap concepts that report it, in order of preference; filers
# change concepts over time, so the one with the newest period wins.
glob FLOW_CONCEPTS: dict[str, list[str]] = {
    "revenue": ["RevenueFromContractWithCustomerExcludingAssessedTax", "Revenues", "SalesRevenueNet", "RevenueFromContractWithCustomerIncludingAssessedTax"],
    "gross_profit": ["GrossProfit"],
    "operating_income": ["OperatingIncomeLoss"],
    "net_income": ["NetIncomeLoss", "ProfitLoss"],
    "operating_cash_flow": ["NetCashProvidedByUsedInOperatingActivities"],
    "capital_expenditure": ["PaymentsToAcquirePropertyPlantAndEquipment"]
};

glob INSTANT_CONCEPTS: dict[str, list[str]] = {
    "total_assets": ["Assets"],
    "total_liabilities": ["Liabilities"],
    "stockholders_equity": ["StockholdersEquity", "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"],
    "cash": ["CashAndCashEquivalentsAtCarryingValue", "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents"],
    "long_term_debt": ["LongTermDebtNoncurrent", "LongTermDebt"]
};

"""Reduce company facts to the figures the Fundamentals sub-agent reads: the latest quarter
against the same quarter a year earlier, trailing twelve months, the latest balance sheet,
and ratios derived from them. Cash-flow concepts are year-to-date in 10-Qs, so their
trailing twelve months are the last fiscal year plus this year to date minus last year's."""
def reduce_facts(symbol: str, cik: str, company: str, facts: dict[str, dict], fetched: Fetched) -> tuple[Fundamentals | None, list[str]] {
    gaap: dict[str, dict] = facts.get("us-gaap") or {};
    values: list[ReportedValue] = [];
    gaps: list[str] = [];
    def add(name: str, value: float, unit: str, period: str, fact: Fact) {
        values.append(ReportedValue(name=name, value=value, unit=unit, period=period, filed=fact.filed, source_url=_filing_index(cik, fact.accession)));
    }
    ttm: dict[str, tuple[float, Fact]] = {};
    for (name, concepts) in FLOW_CONCEPTS.items() {
        series = _series(gaap, concepts, "USD", instant=False);
        if not series {
            gaps.append(f"sec.companyfacts: {symbol} reports no {name.replace('_', ' ')}");
            continue;
        }
        if name not in ("operating_cash_flow", "capital_expenditure") {
            (quarter, prior) = _latest_quarter(series);
            if quarter {
                add(f"{name}_quarter", quarter.value, "USD", f"quarter {quarter.start} to {quarter.end}", quarter);
                if prior and prior.value {
                    # Against the prior value's size, so a smaller loss is growth.
                    growth = (quarter.value - prior.value) / abs(prior.value);
                    add(f"{name}_growth_yoy", growth, "fraction", f"quarter to {quarter.end} vs. quarter to {prior.end}", quarter);
                }
            }
        }
        trailing = _trailing_year(series);
        if trailing {
            (total, latest) = trailing;
            ttm[name] = trailing;
            add(f"{name}_ttm", total, "USD", f"twelve months to {latest.end}", latest);
        }
    }
    eps = _series(gaap, ["EarningsPerShareDiluted"], "USD/shares", instant=False);
    if eps {
        (quarter, prior) = _latest_quarter(eps);
        if quarter {
            add("eps_diluted_quarter", quarter.value, "USD/share", f"quarter {quarter.start} to {quarter.end}", quarter);
            if prior {
                add("eps_diluted_quarter_prior_year", prior.value, "USD/share", f"quarter {prior.start} to {prior.end}", prior);
            }
        }
    }
    balance: dict[str, Fact] = {};
    for (name, concepts) in INSTANT_CONCEPTS.items() {
        series = _series(gaap, concepts, "USD", instant=True);
        if not series {
            gaps.append(f"sec.companyfacts: {symbol} reports no {name.replace('_', ' ')}");
            continue;
        }
        latest = max(series, key=lambda (f: Fact) { (f.end, f.filed); });
        balance[name] = latest;
        add(name, latest.value, "USD", f"as of {latest.end}", latest);
    }
    revenue = ttm.get("revenue");
    if revenue and revenue[0] > 0 {
        for name in ("gross_profit", "operating_income", "net_income") {
            if name in ttm {
                (total, latest) = ttm[name];
                margin = name.replace("_profit", "").replace("_income", "") + "_margin_ttm";
                add(margin, total / revenue[0], "fraction", f"twelve months to {latest.end}", latest);
            }
        }
    }
    if "operating_cash_flow" in ttm and "capital_expenditure" in ttm {
        (cash_flow, latest) = ttm["operating_cash_flow"];
        add("free_cash_flow_ttm", cash_flow - ttm["capital_expenditure"][0], "USD", f"twelve months to {latest.end}", latest);
    }
    if "long_term_debt" in balance and "stockholders_equity" in balance and balance["stockholders_equity"].value > 0 {
        equity = balance["stockholders_equity"];
        add("long_term_debt_to_equity", balance["long_term_debt"].value / equity.value, "ratio", f"as of {equity.end}", equity);
    }
    shares = _series(facts.get("dei") or {}, ["EntityCommonStockSharesOutstanding"], "shares", instant=True);
    if shares {
        latest = max(shares, key=lambda (f: Fact) { (f.end, f.filed); });
        add("shares_outstanding", latest.value, "shares", f"as of {latest.end}", latest);
    }
    if not values {
        return (None, gaps + [f"sec.companyfacts: {symbol} has no usable XBRL facts"]);
    }
    newest = max(values, key=lambda (v: ReportedValue) { v.filed; });
    return (
        Fundamentals(
            symbol=symbol,
            cik=cik,
            company=company,
            values=values,
            stamp=fetched.stamp(newest.filed, source_url=newest.source_url)
        ),
        gaps
    );
}

"""The Form 4 trades in common stock filed from `since` (ISO date) on, newest filings first,
reading at most `limit` filings. Derivative rows (options) are left out."""
def insider_trades(
    symbol: str,
    found: list[Filing],
    since: str,
    budget: RunBudget,
    client: SourceClient | None = None,
    limit: int = 15
) -> tuple[list[InsiderTrade], list[str]] {
    archives = client or sec_archives_client();
    recent = [f for f in found if f.form == "4" and f.filed >= since];
    forms = recent[:limit];
    trades: list[InsiderTrade] = [];
    gaps: list[str] = [];
    for filing in forms {
        document = filing.primary_document.split("/")[-1];
        try {
            fetched = archives.get(
                DATASETS["sec.filing"],
                f"{filing.folder()}/{document}",
                budget,
                symbol=symbol,
                day=filing.filed,
                check=_check_form4
            );
        } except SourceError as e {
            gaps.append(f"sec.filing: Form 4 {filing.accession} for {symbol} is unavailable ({e})");
            continue;
        }
        trades.extend(parse_form4(symbol, filing, fetched));
    }
    if len(recent) > limit {
        gaps.append(f"sec.filing: only the newest {limit} Form 4 filings for {symbol} since {since} were read");
    }
    return (trades, gaps);
}

"""The common-stock transactions in one Form 4."""
def parse_form4(symbol: str, filing: Filing, fetched: Fetched) -> list[InsiderTrade] {
    doc = ET.fromstring(fetched.body);
    owner = doc.find("reportingOwner");
    insider = _text(owner, "reportingOwnerId/rptOwnerName") if owner is not None else "";
    role = _role(owner) if owner is not None else "";
    # Since 2023 a filer marks trades made under a 10b5-1 plan (Rule 10b5-1(c)).
    planned_form = _text(doc, "aff10b5One") in ("1", "true");
    footnotes = " ".join(e.text or "" for e in doc.findall("footnotes/footnote")).lower();
    trades: list[InsiderTrade] = [];
    for row in doc.findall("nonDerivativeTable/nonDerivativeTransaction") {
        day = _text(row, "transactionDate/value")[:10];
        shares = _number(_text(row, "transactionAmounts/transactionShares/value"));
        if not day or shares is None {
            continue;
        }
        trades.append(
            InsiderTrade(
                symbol=symbol,
                insider=insider,
                role=role,
                day=day,
                code=_text(row, "transactionCoding/transactionCode"),
                acquired=_text(row, "transactionAmounts/transactionAcquiredDisposedCode/value") == "A",
                shares=shares,
                price=_number(_text(row, "transactionAmounts/transactionPricePerShare/value")),
                shares_after=_number(_text(row, "postTransactionAmounts/sharesOwnedFollowingTransaction/value")),
                planned=planned_form or "10b5-1" in footnotes,
                filed=filing.filed,
                filing_lag_days=_days(day, filing.filed),
                stamp=fetched.stamp(filing.filed, source_url=filing.index_url())
            )
        );
    }
    return trades;
}

"""The newest Item 2.02 earnings release filed from `since` (ISO date) on, or None."""
def earnings_release(
    symbol: str,
    found: list[Filing],
    since: str,
    budget: RunBudget,
    client: SourceClient | None = None
) -> EarningsRelease | None {
    archives = client or sec_archives_client();
    for filing in eight_ks(found, since) {
        if "2.02" not in filing.items {
            continue;
        }
        index = archives.get(
            DATASETS["sec.filing"],
            f"{filing.folder()}/{filing.accession}-index.htm",
            budget,
            symbol=symbol,
            day=filing.filed,
            check=_check_index
        );
        exhibit = exhibit_path(index.body);
        if not exhibit {
            # An Item 2.02 8-K may furnish its release in the body, or not at all.
            continue;
        }
        fetched = archives.get(DATASETS["sec.filing"], exhibit, budget, symbol=symbol, day=filing.filed);
        url = ARCHIVES + exhibit;
        return EarningsRelease(
            symbol=symbol,
            accession=filing.accession,
            filed=filing.filed,
            exhibit_url=url,
            text=cap(html_to_text(document_html(fetched.body)), MAX_RELEASE_CHARS),
            stamp=fetched.stamp(filing.filed, source_url=url)
        );
    }
    return None;
}

"""The HTML inside an EDGAR document file. Archive copies of exhibits are wrapped in SGML
headers (<DOCUMENT>, <TYPE>, <SEQUENCE>, ...) whose values would read as text."""
def document_html(body: str) -> str {
    start = body.find("<TEXT>");
    if start < 0 or start > 1000 {
        return body;
    }
    end = body.rfind("</TEXT>");
    return body[start + len("<TEXT>"):end if end > start else len(body)];
}

glob _ROW: re.Pattern[str] = re.compile(r"<tr[^>]*>(.*?)</tr>", re.IGNORECASE | re.DOTALL);
glob _CELL: re.Pattern[str] = re.compile(r"<td[^>]*>(.*?)</td>", re.IGNORECASE | re.DOTALL);
glob _HREF: re.Pattern[str] = re.compile(r'href="([^"]+)"', re.IGNORECASE);

"""The archive path of the first EX-99 exhibit in an EDGAR filing index page, or ""."""
def exhibit_path(index_html: str) -> str {
    start = index_html.find('class="tableFile"');
    if start < 0 {
        return "";
    }
    table = index_html[start:index_html.find("</table>", start)];
    for row in _ROW.findall(table) {
        cells = _CELL.findall(row);
        if len(cells) < 4 or not html_to_text(cells[3]).upper().startswith("EX-99") {
            continue;
        }
        link = _HREF.search(row);
        if link {
            # Inline XBRL documents are linked through the viewer as /ix?doc=<path>.
            return link.group(1).split("doc=")[-1];
        }
    }
    return "";
}

"""The company's facts for the first of `concepts` with the newest period, deduplicated to
the newest filing per period."""
def _series(taxonomy: dict[str, dict], concepts: list[str], unit: str, instant: bool) -> list[Fact] {
    best: list[Fact] = [];
    for concept in concepts {
        rows = ((taxonomy.get(concept) or {}).get("units") or {}).get(unit) or [];
        latest: dict[tuple[str, str], Fact] = {};
        for row in rows {
            start = str(row.get("start") or "");
            if (not start) != instant or row.get("val") is None {
                continue;
            }
            fact = Fact(
                concept=concept,
                unit=unit,
                start=start,
                end=str(row["end"]),
                value=float(row["val"]),
                form=str(row.get("form") or ""),
                filed=str(row.get("filed") or ""),
                accession=str(row.get("accn") or "")
            );
            key = (fact.start, fact.end);
            if key not in latest or fact.filed > latest[key].filed {
                latest[key] = fact;
            }
        }
        found = list(latest.values());
        if found and (not best or max(f.end for f in found) > max(f.end for f in best)) {
            best = found;
        }
    }
    return best;
}

"""The newest discrete quarter, and the quarter that ended about a year before it."""
def _latest_quarter(series: list[Fact]) -> tuple[Fact | None, Fact | None] {
    quarters = [f for f in series if QUARTER_DAYS[0] <= f.days() <= QUARTER_DAYS[1]];
    if not quarters {
        return (None, None);
    }
    quarter = max(quarters, key=lambda (f: Fact) { f.end; });
    prior = [f for f in quarters if abs(_days(f.end, quarter.end) - 364) <= PERIOD_SLACK_DAYS];
    return (quarter, prior[0] if prior else None);
}

"""Trailing twelve months to the newest period end, and the fact that dates it, or None."""
def _trailing_year(series: list[Fact]) -> tuple[float, Fact] | None {
    periods = [f for f in series if f.days() > 0];
    if not periods {
        return None;
    }
    end = max(f.end for f in periods);
    latest = max([f for f in periods if f.end == end], key=lambda (f: Fact) { f.days(); });
    if YEAR_DAYS[0] <= latest.days() <= YEAR_DAYS[1] {
        return (latest.value, latest);
    }
    years = [f for f in periods if YEAR_DAYS[0] <= f.days() <= YEAR_DAYS[1] and abs(_days(f.end, latest.start)) <= PERIOD_SLACK_DAYS];
    earlier = [
        f
        for f in periods
        if abs(f.days() - latest.days()) <= PERIOD_SLACK_DAYS and abs(_days(f.end, latest.end) - 364) <= PERIOD_SLACK_DAYS
    ];
    if not years or not earlier {
        return None;
    }
    return (years[0].value + latest.value - earlier[0].value, latest);
}

def _filing_index(cik: str, accession: str) -> str {
    return f"{ARCHIVES}/Archives/edgar/data/{int(cik)}/{accession.replace('-', '')}/{accession}-index.htm";
}

def _days(start: str, end: str) -> int {
    return (date.fromisoformat(end[:10]) - date.fromisoformat(start[:10])).days;
}

def _text(element: ET.Element[str] | None, path: str) -> str {
    if element is None {
        return "";
    }
    found = element.find(path);
    return (found.text or "").strip() if found is not None else "";
}

def _number(text: str) -> float | None {
    try {
        return float(text) if text else None;
    } except ValueError {
        return None;
    }
}

"""The insider's relationship to the company, such as "CEO" or "director"."""
def _role(owner: ET.Element[str]) -> str {
    roles: list[str] = [];
    if _text(owner, "reportingOwnerRelationship/isOfficer") in ("1", "true") {
        roles.append(_text(owner, "reportingOwnerRelationship/officerTitle") or "officer");
    }
    if _text(owner, "reportingOwnerRelationship/isDirector") in ("1", "true") {
        roles.append("director");
    }
    if _text(owner, "reportingOwnerRelationship/isTenPercentOwner") in ("1", "true") {
        roles.append("10% owner");
    }
    return ", ".join(roles) or "other";
}

def _parse(body: str) -> object {
    try {
        return json.loads(body);
    } except ValueError {
        return None;
    }
}

def _check_tickers(body: str) -> str {
    parsed = _parse(body);
    if not isinstance(parsed, dict) or not parsed {
        return f"expected a ticker table: {body[:200]}";
    }
    first = next(iter(parsed.values()));
    return "" if isinstance(first, dict) and "ticker" in first and "cik_str" in first else f"unexpected ticker row: {body[:200]}";
}

def _check_keys(*keys: str) -> Callable[[str], str] {
    def check(body: str) -> str {
        parsed = _parse(body);
        missing = [k for k in keys if not isinstance(parsed, dict) or k not in parsed];
        return f"no {', '.join(missing)} in {body[:200]}" if missing else "";
    }
    return check;
}

def _check_form4(body: str) -> str {
    return "" if "<ownershipDocument" in body[:2000] else f"not a Form 4 XML document: {body[:200]}";
}

def _check_index(body: str) -> str {
    return "" if 'class="tableFile"' in body else f"not an EDGAR filing index: {body[:200]}";
}
