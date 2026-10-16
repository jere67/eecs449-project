"""The Run Guard (run/guard.jac): preflight, the run claim, every tool's limits, the fixed-order
fallback, and the graph a finished run writes, on the stubs in run/stubs.jac, so
no test touches the network."""
import uuid;
import from analysis.consensus { ConsensusConfig }
import from models.graph {
    Counted,
    Covers,
    Decided,
    Decision,
    HasMacro,
    Holds,
    OpenedBy,
    Portfolio,
    PortfolioMode,
    Position,
    Ran,
    Researched,
    Run,
    RunStatus,
    TradeAction
}
import from run.guard { RunLimits, RunOutcome, RunSession, claim_run, count_requests, daily_run, holdings_of, preflight, stored_requests }
import from run.stubs { RUN_DAY, Stubs, collection }

def team -> Portfolio {
    found = Portfolio(name=f"test-{uuid.uuid4()}", mode=PortfolioMode.INSIGHT, starting_cash=0.0, opened_at="2026-10-01T00:00:00+00:00");
    root ++> found;
    return found;
}

"""Run `daily_run` with the stubs installed."""
def run_day(stubs: Stubs, portfolio: Portfolio, driver: Callable[[RunSession], str] | None = None, limits: RunLimits = RunLimits()) -> RunOutcome {
    stubs.install();
    try {
        return daily_run(portfolio, RUN_DAY, driver, limits);
    } finally {
        stubs.restore();
    }
}

"""A well-behaved Orchestrator, scripted: research, one follow-up, the panel, the submission,
and a summary."""
def scripted_driver(s: RunSession) -> str {
    s.get_run_context();
    s.dispatch_research(s.tickers(), ["market", "fundamentals", "news"]);
    s.request_followup("AAPL", "news", "Is the recall priced in?");
    s.convene_panel(s.tickers());
    s.submit_decisions("All covered.");
    s.write_run_summary("Two buys on strong panels.");
    return "done";
}

"""An Orchestrator that answers without using a tool."""
def idle_driver(_s: RunSession) -> str {
    return "nothing to do";
}

def decisions_of(run: Run | None) -> dict[str, Decision] {
    assert run is not None;
    found: dict[str, Decision] = {};
    for cov in [run ->:Covers:->] {
        for d in [cov ->:Decided:->[?:Decision]] {
            found[cov.ticker] = d;
        }
    }
    return found;
}

test "with no Orchestrator the run finishes in fixed order, marked fallback, and is recorded" {
    portfolio = team();
    outcome = run_day(Stubs(), portfolio);
    assert outcome.status == RunStatus.FALLBACK;
    run = outcome.run;
    assert run is not None and run.status == RunStatus.FALLBACK and run.finished_at;
    assert run.summary.startswith("2 tickers decided by the Run Guard's fixed order (fallback): 2 BUY.");
    assert run.model_versions["consensus"] and not run.reduced_mode;
    assert [r for r in [portfolio ->:Ran:->]] == [run];
    decided = decisions_of(run);
    assert {t: d.action for (t, d) in decided.items()} == {"AAPL": TradeAction.BUY, "MSFT": TradeAction.BUY};
    covered = [run ->:Covers:->];
    assert all(len([c ->:Researched:->]) == 3 for c in covered);
    assert len([run ->:HasMacro:->]) == 1;
    assert len([portfolio ->:Counted:->]) == 1;
}

test "an Orchestrator that submits makes a normal run, with its follow-up and summary recorded" {
    portfolio = team();
    outcome = run_day(Stubs(), portfolio, scripted_driver);
    assert outcome.status == RunStatus.NORMAL;
    run = outcome.run;
    assert run is not None and run.summary == "Two buys on strong panels.";
    aapl = [c for c in [run ->:Covers:->] if c.ticker == "AAPL"][0];
    records = [aapl ->:Researched:->];
    assert len(records) == 4;
    assert [r.followup_question for r in records if r.followup_question] == ["Is the recall priced in?"];
}

test "an Orchestrator that raises, or ends without submitting, hands the run to the fallback" {
    def broken(s: RunSession) -> str {
        s.dispatch_research(["AAPL"], ["market"]);
        raise RuntimeError("tool loop crashed");
    }
    outcome = run_day(Stubs(), team(), broken);
    assert outcome.status == RunStatus.FALLBACK;
    session = outcome.session;
    assert session is not None and "orchestrator error: RuntimeError: tool loop crashed" in session.actions;
    assert len(decisions_of(outcome.run)) == 2;
    quiet = run_day(Stubs(), team(), idle_driver);
    assert quiet.status == RunStatus.FALLBACK;
    assert quiet.run is not None and quiet.run.summary == "nothing to do";
}

test "a holiday is skipped, and a second firing for the same date does nothing" {
    portfolio = team();
    skipped = run_day(Stubs(trading=False), portfolio);
    assert skipped.status == RunStatus.SKIPPED and skipped.run is not None;
    assert skipped.run.summary == "Skipped: 2026-10-16 is not a trading day.";
    again = run_day(Stubs(), portfolio);
    assert again.status == RunStatus.SKIPPED and again.run is None;
    assert again.note == "the run for 2026-10-16 was already claimed";
    assert len([portfolio ->:Ran:->]) == 1;
}

test "a failed collection fails the run and holds every open position" {
    portfolio = team();
    position = Position(ticker="XOM", sector="Energy", qty=10, avg_entry_price=100.0, opened_at="2026-10-01T15:00:00+00:00");
    portfolio +>:Holds():+> position;
    outcome = run_day(Stubs(collect_error="Wikipedia is down"), portfolio);
    assert outcome.status == RunStatus.FAILED;
    decided = decisions_of(outcome.run);
    assert list(decided) == ["XOM"] and decided["XOM"].action == TradeAction.HOLD;
    assert decided["XOM"].forced_hold_reason == "collection failed: RuntimeError: Wikipedia is down";
}

test "preflight takes the lower of the app's count and OpenRouter's, and runs reduced under 500" {
    portfolio = team();
    count_requests(portfolio, "2000-01-01", 999);
    stubs = Stubs(provider_left=450);
    stubs.install();
    try {
        checked = preflight(RUN_DAY, portfolio);
    } finally {
        stubs.restore();
    }
    assert checked.trading_day and checked.provider_left == 450;
    assert checked.requests_left == 450 and checked.reduced and checked.run_requests == 450;
    assert stored_requests(portfolio, "2000-01-01") == 999;
    count_requests(portfolio, "2000-01-01", 1);
    assert stored_requests(portfolio, "2000-01-01") == 1000;
}

test "a reduced run screens 10 tickers and draws one sample per specialist" {
    stubs = Stubs(provider_left=300, symbols=["AAPL"]);
    outcome = run_day(stubs, team());
    assert outcome.run is not None and outcome.run.reduced_mode;
    session = outcome.session;
    assert session is not None and session.config.samples == 1 and session.config.extra_samples == 0;
    assert stubs.specialist_llm is not None and len(stubs.specialist_llm.seen_prompts) == 5;
    assert stubs.shortlist_sizes == [10];
}

test "reduced mode never screens or samples more than the standard limits" {
    stubs = Stubs(provider_left=300, symbols=["AAPL"]);
    outcome = run_day(stubs, team(), None, RunLimits(shortlist=5, samples=1, reduced_samples=2));
    assert stubs.shortlist_sizes == [5];
    session = outcome.session;
    assert session is not None and session.config.samples == 1;
}

test "the run claim is taken once per date" {
    portfolio = team();
    first = claim_run(portfolio, "2026-10-19");
    assert first is not None and first.status == RunStatus.RUNNING;
    assert claim_run(portfolio, "2026-10-19") is None;
    assert claim_run(portfolio, "2026-10-20") is not None;
}

test "a held position's time stop comes from the decision that opened it" {
    portfolio = team();
    position = Position(ticker="XOM", sector="Energy", qty=10, avg_entry_price=100.0, opened_at="2026-10-01T15:00:00+00:00");
    portfolio +>:Holds():+> position;
    position +>:OpenedBy():+> Decision(ticker="XOM", action=TradeAction.BUY, conviction=0.4, time_stop="2026-10-16");
    held = holdings_of(portfolio);
    assert list(held) == ["XOM"] and held["XOM"].time_stop == "2026-10-16";
    outcome = run_day(Stubs(symbols=["AAPL"]), portfolio);
    decided = decisions_of(outcome.run);
    assert decided["XOM"].action == TradeAction.SELL and decided["AAPL"].action == TradeAction.BUY;
}

"""A session on a stubbed collection, with every model mocked, for the tool tests."""
def session_with(stubs: Stubs, run_requests: int = 600) -> RunSession {
    return RunSession(run_day=RUN_DAY, collection=collection(stubs.symbols, []), holdings={}, config=ConsensusConfig(), limits=RunLimits(), run_requests=run_requests);
}

test "every tool enforces its limits and says why it refuses" {
    stubs = Stubs();
    stubs.install();
    try {
        s = session_with(stubs);
        assert "NVDA: not covered in this run" in s.dispatch_research(["NVDA"], ["market"]);
        assert "options: not a research domain" in s.dispatch_research(["AAPL"], ["options"]);
        assert s.request_followup("AAPL", "news", "Why?") == "Refused: AAPL news: dispatch research first.";
        assert "dispatch market, fundamentals, and news research first" in s.convene_panel(["AAPL"]);
        first = s.dispatch_research(["aapl", "AAPL"], ["market", "fundamentals", "news"]);
        assert "AAPL: market complete" in first;
        assert "AAPL market: already researched" in s.dispatch_research(["AAPL"], ["market"]);
        assert s.request_followup("AAPL", "news", "  ") == "Refused: a follow-up needs a question.";
        assert s.request_followup("AAPL", "news", "One?").startswith("AAPL news: complete");
        assert s.request_followup("AAPL", "market", "Two?").startswith("AAPL market: complete");
        assert s.request_followup("AAPL", "news", "Three?") == "Refused: AAPL: already had 2 follow-ups.";
        assert s.submit_decisions("early").startswith("Refused: no decision yet for AAPL, MSFT");
        assert "AAPL: BUY" in s.convene_panel(["AAPL"]);
        assert "AAPL: already decided" in s.convene_panel(["AAPL"]);
        assert s.flag_ticker("MSFT", "") == "Refused: a flag needs a reason.";
        assert s.flag_ticker("MSFT", "Conflicting filings.") == "MSFT flagged; it will be decided HOLD.";
        assert "MSFT: HOLD (flagged)" in s.convene_panel(["MSFT"]);
        assert s.submit_decisions("All in.") == "Submitted 2 decisions: 1 BUY, 1 HOLD.";
        assert s.submit_decisions("again") == "Refused: decisions are already submitted.";
        assert s.flag_ticker("AAPL", "late") == "Refused: decisions are already submitted.";
        assert s.write_run_summary("Done.") == "Summary stored.";
        assert s.write_run_summary("Again.") == "Refused: the summary is already written.";
        assert "MSFT (Information Technology; score): HOLD (flagged by the Orchestrator: Conflicting filings.)" in s.get_run_context();
    } finally {
        stubs.restore();
    }
}

test "a flag after the panel turns the decision into HOLD" {
    stubs = Stubs(symbols=["AAPL"]);
    stubs.install();
    try {
        s = session_with(stubs);
        s.dispatch_research(["AAPL"], ["market", "fundamentals", "news"]);
        s.convene_panel(["AAPL"]);
        assert s.analyses["AAPL"].action() == TradeAction.BUY;
        s.flag_ticker("AAPL", "Halted.");
        assert s.analyses["AAPL"].action() == TradeAction.HOLD;
        assert s.analyses["AAPL"].forced_hold_reason == "flagged by the Orchestrator: Halted.";
    } finally {
        stubs.restore();
    }
}

test "with no request budget, nothing runs and every ticker still holds" {
    stubs = Stubs();
    stubs.install();
    try {
        s = session_with(stubs, run_requests=0);
        assert "AAPL market: not run, the run's request budget is spent" in s.dispatch_research(["AAPL"], ["market"]);
        s.complete_in_order();
    } finally {
        stubs.restore();
    }
    assert s.submitted;
    assert {t: a.forced_hold_reason for (t, a) in s.analyses.items()} == {"AAPL": "the run could not finish its research or panel", "MSFT": "the run could not finish its research or panel"};
    assert stubs.research_llm is not None and stubs.research_llm.seen_prompts == [];
}
