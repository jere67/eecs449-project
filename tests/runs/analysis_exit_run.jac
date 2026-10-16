"""Analysis exit run (#70): one live morning run driven by the Orchestrator, then two fallback
drills, each written to its own test portfolio and timed, with every tool call logged.

The exit criterion is a full dry run that produces valid decisions for every covered ticker
within the request budget, and a fallback mode that passes its drill (TDD §15). The drills:

- Kill switch: no model may be called, so the Orchestrator fails at once and every ticker
  must still end with a decision (TDD §2, principle 6). Spends no model requests.
- Orchestrator down: the driver fails before any tool, and the Run Guard runs research and
  the panel in fixed order on a 5-ticker shortlist. Spends about 100 model requests.

The main run spends about 460 free-model requests, so this runs only when asked; `jac test`
executes every module's entry block:

    set -a && source .env && set +a
    TRADING_AGENT_RUN_ANALYSIS_EXIT=1 EXIT_OUT=/tmp/analysis-exit.json jac run --no-takeover tests/runs/analysis_exit_run.jac

EXIT_RUN_DAY sets the trading day (default: today in New York), and EXIT_PARTS picks the
parts to run (default "main,kill,down"). Findings: docs/runs/.
"""
import functools;
import json;
import os;
import time;
import uuid;
import from datetime { datetime }
import from pathlib { Path }
import from zoneinfo { ZoneInfo }
import from agents.models { KILL_SWITCH_ENV, LIMITER, provider_requests_left }
import from models.graph { Concluded, Covers, Decided, Decision, Portfolio, PortfolioMode, Researched, Run, Voted }
import from run.analysis { TickerAnalysis }
import from run.guard { RunLimits, RunOutcome, RunSession, daily_run }
import from run.orchestration { orchestrate }

glob RUN_ENV: str = "TRADING_AGENT_RUN_ANALYSIS_EXIT";
glob TOOLS: list[str] = ["get_run_context", "dispatch_research", "request_followup", "flag_ticker", "convene_panel", "submit_decisions", "write_run_summary"];

"""One tool call: when it started (seconds into the run), how long it took, the model requests
it made, and the start of its result."""
obj ToolUse {
    has name: str,
        at: float,
        seconds: float,
        requests: int,
        args: str,
        result: str;
}

"""Replace the session's tools with timed copies that keep each tool's name, signature, and
docstring, so the Orchestrator sees the same tools and the fallback's calls are logged too."""
def instrument(s: RunSession, log: list[ToolUse]) {
    started = time.monotonic();
    for name in TOOLS {
        setattr(s, name, timed(name, getattr(s, name), log, started));
    }
}

def timed(name: str, tool: Callable[..., str], log: list[ToolUse], started: float) -> Callable[..., str] {
    @functools.wraps(tool)
    def call(*args: object, **kwargs: object) -> str {
        (clock, before) = (time.monotonic(), LIMITER.sent);
        result = tool(*args, **kwargs);
        log.append(ToolUse(name=name, at=round(clock - started, 1), seconds=round(time.monotonic() - clock, 1), requests=LIMITER.sent - before, args=json.dumps({"args": [str(a) for a in args], "kwargs": {k: str(v) for (k, v) in kwargs.items()}})[:400], result=result[:600]));
        return result;
    }
    return call;
}

def portfolio(label: str, started: str) -> Portfolio {
    team = Portfolio(name=f"analysis-exit-{label}-{uuid.uuid4()}", mode=PortfolioMode.INSIGHT, starting_cash=0.0, opened_at=started);
    root ++> team;
    return team;
}

"""A decision is valid when it holds for a stated reason, or carries the Arbiter's thesis, two
risks, an exit condition, and a time stop (FR-07)."""
def valid_decision(d: Decision) -> bool {
    if d.forced_hold_reason {
        return bool(d.time_stop) or d.thesis.startswith("No panel decision");
    }
    return bool(d.thesis and len(d.risks) == 2 and d.exit_condition and d.time_stop);
}

def ticker_row(a: TickerAnalysis, s: RunSession) -> dict[str, object] {
    c = a.consensus;
    ruling = a.ruling;
    return {
        "ticker": a.ticker,
        "held": a.held,
        "action": a.action().value,
        "draft": a.draft.value,
        "score": round(c.score, 4) if c is not None else None,
        "agreement": round(c.agreement, 4) if c is not None else None,
        "interval": [round(c.ci_low, 4), round(c.ci_high, 4)] if c is not None else None,
        "specialist_scores": {k: round(v, 3) for (k, v) in c.specialist_scores.items()} if c is not None else {},
        "conviction": round(a.conviction(), 4),
        "samples": {"valid": a.valid_count(), "attempted": len(a.votes)},
        "dropped": [f"{r.specialist.value}#{r.sample}: {r.error}" for r in a.votes if not r.valid()],
        "retried_samples": len([r for r in a.votes if r.retried]),
        "resampled": a.resampled,
        "forced_hold_reason": a.forced_hold_reason,
        "verdict": ruling.verdict if ruling is not None else "",
        "downgrade_reason": ruling.downgrade_reason if ruling is not None else "",
        "arbiter_error": ruling.error if ruling is not None else "",
        "thesis": ruling.thesis if ruling is not None else "",
        "risks": ruling.risks if ruling is not None else [],
        "exit_condition": ruling.exit_condition if ruling is not None else "",
        "time_stop": a.time_stop,
        "followups": s.followups.get(a.ticker, 0),
        "flag": s.flags.get(a.ticker, ""),
        "research": {d.value: {"complete": r.complete(), "cited": r.cited, "error": r.error, "view": r.body.view.value} for (d, r) in s.latest.get(a.ticker, {}).items()},
        "votes": [{"specialist": r.specialist.value, "sample": r.sample, "stance": r.vote.stance.value, "confidence": r.vote.confidence, "horizon": r.vote.horizon_days, "rationale": r.vote.rationale, "cited": r.vote.cited_evidence} for r in a.votes if r.vote is not None]
    };
}

def graph_counts(run: Run | None) -> dict[str, int] {
    if run is None {
        return {};
    }
    covered = [run ->:Covers:->];
    return {
        "coverage": len(covered),
        "research_records": sum(len([c ->:Researched:->]) for c in covered),
        "vote_records": sum(len([c ->:Voted:->]) for c in covered),
        "consensus_results": sum(len([c ->:Concluded:->]) for c in covered),
        "decisions": sum(len([c ->:Decided:->]) for c in covered),
        "valid_decisions": sum(len([d for d in [c ->:Decided:->[?:Decision]] if valid_decision(d)]) for c in covered)
    };
}

def outcome_row(label: str, o: RunOutcome, seconds: float, requests: int, fallbacks: int, log: list[ToolUse]) -> dict[str, object] {
    s = o.session;
    row: dict[str, object] = {
        "part": label,
        "status": o.status.value,
        "note": o.note,
        "seconds": round(seconds, 1),
        "model_requests": requests,
        "fallback_model_requests": fallbacks,
        "graph": graph_counts(o.run),
        "summary": o.run.summary if o.run is not None else "",
        "tools": [{"name": t.name, "at": t.at, "seconds": t.seconds, "requests": t.requests, "args": t.args, "result": t.result} for t in log]
    };
    if o.preflight is not None {
        p = o.preflight;
        row["preflight"] = {"trading_day": p.trading_day, "note": p.note, "own_used": p.own_used, "provider_left": p.provider_left, "requests_left": p.requests_left, "reduced": p.reduced, "run_requests": p.run_requests};
    }
    if s is not None {
        row["shortlist"] = [{"symbol": p.symbol, "sector": p.sector, "reason": p.reason.value, "score": p.score} for p in s.collection.shortlist.picks];
        row["collection_seconds"] = {k: round(v, 1) for (k, v) in s.collection.phase_seconds.items()};
        row["source_calls"] = s.collection.source_calls;
        row["macro"] = {"regime": s.macro.body.regime.value, "confidence": s.macro.body.confidence, "complete": s.macro.complete(), "error": s.macro.error} if s.macro is not None else None;
        row["actions"] = s.actions;
        row["covered_all"] = all(t in s.analyses for t in s.tickers());
        row["tickers"] = [ticker_row(s.analyses[t], s) for t in s.tickers() if t in s.analyses];
    }
    return row;
}

"""Run one part, timed, with its tool calls logged."""
def run_part(label: str, run_day: str, driver: Callable[[RunSession], str], limits: RunLimits) -> dict[str, object] {
    log: list[ToolUse] = [];
    def logged(s: RunSession) -> str {
        instrument(s, log);
        return driver(s);
    }
    (clock, before, fallbacks) = (time.monotonic(), LIMITER.sent, LIMITER.fallbacks);
    team = portfolio(label, datetime.now(ZoneInfo("UTC")).isoformat());
    outcome = daily_run(team, run_day, logged, limits);
    return outcome_row(label, outcome, time.monotonic() - clock, LIMITER.sent - before, LIMITER.fallbacks - fallbacks, log);
}

"""The drill's broken Orchestrator: it fails before calling any tool."""
def orchestrator_down(_s: RunSession) -> str {
    raise RuntimeError("drill: the Orchestrator is down");
}

with entry {
    if os.environ.get(RUN_ENV) == "1" {
        out = Path(os.environ.get("EXIT_OUT", "analysis-exit.json"));
        run_day = os.environ.get("EXIT_RUN_DAY") or datetime.now(ZoneInfo("America/New_York")).date().isoformat();
        parts = [p.strip() for p in os.environ.get("EXIT_PARTS", "main,kill,down").split(",") if p.strip()];
        results: dict[str, object] = {"run_day": run_day, "provider_left_before": provider_requests_left(), "parts": []};
        found: list[dict[str, object]] = [];
        if "main" in parts {
            found.append(run_part("main", run_day, orchestrate, RunLimits(shortlist=20)));
            out.write_text(json.dumps({**results, "parts": found}, indent=1));
        }
        if "kill" in parts {
            os.environ[KILL_SWITCH_ENV] = "1";
            try {
                found.append(run_part("kill", run_day, orchestrate, RunLimits(shortlist=20)));
            } finally {
                del os.environ[KILL_SWITCH_ENV];
            }
            out.write_text(json.dumps({**results, "parts": found}, indent=1));
        }
        if "down" in parts {
            found.append(run_part("down", run_day, orchestrator_down, RunLimits(shortlist=5)));
        }
        results["parts"] = found;
        results["provider_left_after"] = provider_requests_left();
        out.write_text(json.dumps(results, indent=1));
    }
}
