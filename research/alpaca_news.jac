"""Benzinga news through Alpaca (TDD §5 step 5, §6): 3-day article counts for the screener,
and capped article text for the News sub-agent.

Article text is untrusted (TDD §14): it is reduced to plain text, capped, and handed to an
agent only through `Article.as_untrusted`.
"""
import json;
import from urllib.parse { urlencode }
import from models.research { Stamped }
import from research.alpaca { alpaca_data_client }
import from research.collector { RunBudget, SourceClient }
import from research.sources { DATASETS, SOURCES }
import from research.text { cap, html_to_text, untrusted_block }

# Alpaca's largest page; a larger limit is refused with status 400.
glob ARTICLES_PER_PAGE: int = 50;
# Three days of news for the whole index took 27 pages (checked 2026-10-08).
glob MAX_COUNT_PAGES: int = 100;
glob MAX_HEADLINE_CHARS: int = 300;
glob MAX_SUMMARY_CHARS: int = 1000;
glob MAX_CONTENT_CHARS: int = 4000;

obj Article(Stamped) {
    has id: int,
        headline: str,
        summary: str,
        content: str,
        author: str,
        source: str,
        url: str,
        symbols: list[str],
        created_at: str,
        updated_at: str;

    """The article as untrusted data for a research sub-agent's prompt."""
    def as_untrusted -> str {
        text = "\n\n".join(part for part in [self.headline, self.summary, self.content] if part);
        return untrusted_block(
            "news article",
            text,
            {"source": self.source, "published": self.created_at, "url": self.url}
        );
    }
}

"""How many articles since `start` (an ISO date or timestamp) name each symbol, for the
screener's news score. A symbol with none counts 0. Returns the counts and any gap."""
def article_counts(
    symbols: list[str],
    start: str,
    budget: RunBudget,
    client: SourceClient | None = None
) -> tuple[dict[str, int], list[str]] {
    data = client or alpaca_data_client();
    wanted = sorted(set(symbols));
    counts = {symbol: 0 for symbol in wanted};
    token = "";
    for _ in range(MAX_COUNT_PAGES) {
        params: dict[str, str | int | float] = {
            "symbols": ",".join(wanted),
            "start": start,
            "limit": ARTICLES_PER_PAGE,
            "include_content": "false",
            "sort": "desc"
        };
        if token {
            params["page_token"] = token;
        }
        page = json.loads(data.get(DATASETS["alpaca.news"], "/v1beta1/news", budget, params=params, check=_check_news).body);
        for row in page["news"] {
            for symbol in row.get("symbols") or [] {
                if symbol in counts {
                    counts[symbol] += 1;
                }
            }
        }
        token = page.get("next_page_token") or "";
        if not token {
            return (counts, []);
        }
    }
    return (
        counts,
        [f"alpaca.news: article counts since {start} stopped after {MAX_COUNT_PAGES} pages, so they are undercounts"]
    );
}

"""The newest `limit` articles naming `symbol` since `start`, with capped plain text."""
def articles(
    symbol: str,
    start: str,
    budget: RunBudget,
    client: SourceClient | None = None,
    limit: int = 20
) -> list[Article] {
    fetched = (client or alpaca_data_client()).get(
        DATASETS["alpaca.news"],
        "/v1beta1/news",
        budget,
        params={
            "symbols": symbol,
            "start": start,
            "limit": min(limit, ARTICLES_PER_PAGE),
            "include_content": "true",
            "sort": "desc"
        },
        symbol=symbol,
        check=_check_news
    );
    found: list[Article] = [];
    for row in json.loads(fetched.body)["news"][:limit] {
        page_url = row.get("url") or SOURCES["alpaca_data"].base_url + "/v1beta1/news?" + urlencode({"symbols": symbol});
        found.append(
            Article(
                id=int(row["id"]),
                headline=cap(html_to_text(row.get("headline") or ""), MAX_HEADLINE_CHARS),
                summary=cap(html_to_text(row.get("summary") or ""), MAX_SUMMARY_CHARS),
                content=cap(html_to_text(row.get("content") or ""), MAX_CONTENT_CHARS),
                author=row.get("author") or "",
                source=row.get("source") or "",
                url=row.get("url") or "",
                symbols=list(row.get("symbols") or []),
                created_at=row["created_at"],
                updated_at=row.get("updated_at") or row["created_at"],
                stamp=fetched.stamp(row["created_at"], source_url=page_url)
            )
        );
    }
    return found;
}

def _check_news(body: str) -> str {
    try {
        parsed = json.loads(body);
    } except ValueError {
        return f"not JSON: {body[:200]}";
    }
    return "" if isinstance(parsed, dict) and isinstance(parsed.get("news"), list) else f"no news list in {body[:200]}";
}
