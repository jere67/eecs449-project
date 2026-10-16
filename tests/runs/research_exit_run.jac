"""Research exit run (#27): one live research pass on a 20-ticker shortlist, timed, with
report completeness, citation coverage, and model requests, written to the team graph.

The exit criterion is a 20-ticker pass in under 30 minutes with at least 90% of reports
complete and every claim cited. This calls every live source and spends about 70 free-model
requests, so it runs only when asked; `jac test` executes every module's entry block:

    set -a && source .env && set +a
    TRADING_AGENT_RUN_EXIT=1 EXIT_OUT=/tmp/exit.json jac run --no-takeover tests/runs/research_exit_run.jac

EXIT_RUN_DAY sets the trading day (default: today in New York). Findings: docs/runs/.
"""
import json;
import os;
import uuid;
import from datetime { datetime }
import from pathlib { Path }
import from zoneinfo { ZoneInfo }
import httpx;
import from agents.research { MacroResult, ResearchResult }
import from models.agents { Evidence }
import from models.graph { Covers, HasMacro, Portfolio, PortfolioMode, Researched }
import from research.screener { ScreenConfig }
import from run.research { PassConfig, ResearchPass, record_pass, research_pass }

glob RUN_ENV: str = "TRADING_AGENT_RUN_EXIT";
glob SHORTLIST_SIZE: int = 20;

"""OpenRouter's own count of today's free-model requests, to check the limiter's count."""
def free_requests_used -> int | None {
    try {
        response = httpx.get("https://openrouter.ai/api/v1/key", headers={"Authorization": f"Bearer {os.environ.get('OPENROUTER_API_KEY', '')}"}, timeout=30);
        return (response.json().get("data") or {}).get("free_model_daily_requests");
    } except Exception {
        return None;
    }
}

def evidence(items: list[Evidence]) -> list[dict[str, str]] {
    return [{"claim": e.claim, "source_url": e.source_url, "published": e.published} for e in items];
}

def report_row(r: ResearchResult) -> dict[str, object] {
    return {
        "domain": r.domain.value,
        "ok": r.ok,
        "complete": r.complete(),
        "error": r.error,
        "model": r.model,
        "retried": r.retried,
        "cited": r.cited,
        "dropped_citations": r.dropped_citations,
        "seconds": round(r.seconds, 1),
        "view": r.body.view.value,
        "confidence": r.body.confidence,
        "summary": r.body.summary,
        "evidence": evidence(r.body.evidence),
        "risks": r.body.risks,
        "data_gaps": r.body.data_gaps
    };
}

def macro_row(m: MacroResult) -> dict[str, object] {
    return {
        "ok": m.ok,
        "complete": m.complete(),
        "error": m.error,
        "model": m.model,
        "retried": m.retried,
        "cited": m.cited,
        "dropped_citations": m.dropped_citations,
        "seconds": round(m.seconds, 1),
        "regime": m.body.regime.value,
        "confidence": m.body.confidence,
        "summary": m.body.summary,
        "evidence": evidence(m.body.evidence),
        "risks": m.body.risks,
        "data_gaps": m.body.data_gaps
    };
}

def summary(done: ResearchPass, free_before: int | None, free_after: int | None, written: dict[str, int]) -> dict[str, object] {
    found = done.reports();
    return {
        "run_day": done.run_day,
        "started_at": done.started_at,
        "finished_at": done.finished_at,
        "seconds": round(done.seconds(), 1),
        "phase_seconds": {k: round(v, 1) for (k, v) in done.phase_seconds.items()},
        "tickers": len(done.tickers),
        "reports": len(found),
        "complete_reports": len([r for r in found if r.complete()]),
        "completeness": done.completeness(),
        "citation_rate": done.citation_rate(),
        "claims_cited": sum(r.cited for r in found) + done.macro.cited,
        "claims_dropped": sum(r.dropped_citations for r in found) + done.macro.dropped_citations,
        "retried": len([r for r in found if r.retried]) + (1 if done.macro.retried else 0),
        "model_requests": done.model_requests,
        "fallback_requests": done.fallbacks,
        "openrouter_free_requests": {"before": free_before, "after": free_after},
        "source_calls": done.source_calls,
        "graph": written,
        "regime": {
            "spy_close": done.regime.spy_close,
            "spy_sma_200": done.regime.spy_sma_200,
            "spy_vol_20": done.regime.spy_vol_20,
            "spy_as_of": done.regime.spy_as_of
        },
        "shortlist": [{"symbol": p.symbol, "sector": p.sector, "reason": p.reason.value, "score": p.score} for p in done.shortlist.picks],
        "pass_gaps": done.gaps,
        "macro": macro_row(done.macro),
        "per_ticker": [{"symbol": t.pick.symbol, "fetch_errors": t.fetch_errors, "reports": [report_row(r) for r in t.reports]} for t in done.tickers]
    };
}

with entry {
    if os.environ.get(RUN_ENV) == "1" {
        out = Path(os.environ.get("EXIT_OUT", "exit-run.json"));
        run_day = os.environ.get("EXIT_RUN_DAY") or datetime.now(ZoneInfo("America/New_York")).date().isoformat();
        free_before = free_requests_used();
        done = research_pass(run_day, [], PassConfig(screen=ScreenConfig(shortlist_size=SHORTLIST_SIZE)));
        free_after = free_requests_used();
        team = Portfolio(name=f"exit-run-{uuid.uuid4()}", mode=PortfolioMode.INSIGHT, starting_cash=0.0, opened_at=done.started_at);
        root ++> team;
        run = record_pass(team, done);
        covered = [run ->:Covers:->];
        written = {
            "coverage": len(covered),
            "research_records": sum(len([c ->:Researched:->]) for c in covered),
            "macro_records": len([run ->:HasMacro:->])
        };
        out.write_text(json.dumps(summary(done, free_before, free_after, written), indent=1));
    }
}
