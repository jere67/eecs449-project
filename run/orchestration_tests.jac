"""The Orchestrator's loop over a run session (run/orchestration.jac, agents/orchestrator.jac),
with MockLLM scripted to call the session's tools: a full run, a clamped follow-up, the budget
hook, the iteration cap, and a failing model. Uses the whole-run stubs in
tests/fakes/run_stubs.jac, so no test touches the network."""
import uuid;
import agents.orchestrator as orchestrator_module;
import from jaclang.byllm.lib { MockError, MockLLM, MockToolCall }
import from analysis.consensus { ConsensusConfig }
import from models.graph { Portfolio, PortfolioMode, RunStatus, TradeAction }
import from run.guard { RunLimits, RunSession, daily_run }
import from run.orchestration { orchestrate }
import from tests.fakes.run_stubs { RUN_DAY, Stubs, collection }

def session_with(stubs: Stubs, run_requests: int = 600, iterations: int = 12) -> RunSession {
    return RunSession(run_day=RUN_DAY, collection=collection(stubs.symbols, []), holdings={}, config=ConsensusConfig(), limits=RunLimits(react_iterations=iterations), run_requests=run_requests);
}

"""The tool calls of a well-behaved run, with one follow-up too many, then its final answer."""
def full_script(s: RunSession) -> list[object] {
    return [
        MockToolCall(tool=s.get_run_context, args={}),
        MockToolCall(tool=s.dispatch_research, args={"tickers": ["AAPL", "MSFT"], "domains": ["market", "fundamentals", "news"]}),
        [
            MockToolCall(tool=s.request_followup, args={"ticker": "AAPL", "domain": "news", "question": "Is the recall priced in?"}),
            MockToolCall(tool=s.request_followup, args={"ticker": "AAPL", "domain": "market", "question": "Is the breakout confirmed?"})
        ],
        MockToolCall(tool=s.request_followup, args={"ticker": "AAPL", "domain": "fundamentals", "question": "A third?"}),
        MockToolCall(tool=s.convene_panel, args={"tickers": ["AAPL", "MSFT"]}),
        MockToolCall(tool=s.submit_decisions, args={"note": "Both covered."}),
        MockToolCall(tool=s.write_run_summary, args={"text": "Two buys on strong panels."}),
        "The committee bought AAPL and MSFT."
    ];
}

"""Run `orchestrate` on `s` with the Orchestrator's model scripted by `script(s)`."""
def drive(s: RunSession, script: Callable[[RunSession], list[object]]) -> tuple[str, MockLLM] {
    model = MockLLM(model_name="mock-orchestrator", config={"outputs": script(s)});
    saved = orchestrator_module.orchestrator_llm;
    setattr(orchestrator_module, "orchestrator_llm", model);
    try {
        return (orchestrate(s), model);
    } finally {
        setattr(orchestrator_module, "orchestrator_llm", saved);
    }
}

test "the Orchestrator runs the session through its tools, and the tools clamp its limits" {
    stubs = Stubs();
    stubs.install();
    try {
        s = session_with(stubs);
        (said, model) = drive(s, full_script);
    } finally {
        stubs.restore();
    }
    assert said == "The committee bought AAPL and MSFT.";
    assert s.submitted and s.summary == "Two buys on strong panels.";
    assert s.followups == {"AAPL": 2};
    assert {t: a.action() for (t, a) in s.analyses.items()} == {"AAPL": TradeAction.BUY, "MSFT": TradeAction.BUY};
    prompts = model.seen_prompts;
    assert len(prompts) == 8;
    # The prompt carries the run date and tickers, and the committee, not a list of callables.
    assert "2026-10-16" in prompts[0] and "AAPL, MSFT" in prompts[0];
    assert "investment committee's morning run" in prompts[0] and "<bound method" not in prompts[0];
    # The refused third follow-up came back to the model as a tool result.
    assert "Refused: AAPL: already had 2 follow-ups." in prompts[4];
}

test "the loop stops with a summary once the run's budget is down to the reserve" {
    stubs = Stubs();
    stubs.install();
    try {
        s = session_with(stubs, run_requests=2);
        (said, model) = drive(s, lambda (s: RunSession) { [MockToolCall(tool=s.get_run_context, args={}), "Stopped: the budget is spent."]; });
    } finally {
        stubs.restore();
    }
    assert said == "Stopped: the budget is spent.";
    assert "orchestrator stopped at iteration 2: request budget spent" in s.actions;
    assert not s.submitted and len(model.seen_prompts) == 2;
}

test "the loop ends at its iteration cap with a final answer" {
    stubs = Stubs();
    stubs.install();
    try {
        s = session_with(stubs, iterations=2);
        script = lambda (s: RunSession) { [MockToolCall(tool=s.get_run_context, args={}), MockToolCall(tool=s.get_run_context, args={}), "Out of steps."]; };
        (said, model) = drive(s, script);
    } finally {
        stubs.restore();
    }
    assert said == "Out of steps." and len(model.seen_prompts) == 3;
    assert model.config["outputs"] == [];
}

def team -> Portfolio {
    found = Portfolio(name=f"test-{uuid.uuid4()}", mode=PortfolioMode.INSIGHT, starting_cash=0.0, opened_at="2026-10-01T00:00:00+00:00");
    root ++> found;
    return found;
}

"""A driver that scripts the Orchestrator's model once the session exists, then runs it."""
def scripted(outputs: Callable[[RunSession], list[object]]) -> Callable[[RunSession], str] {
    def run_it(s: RunSession) -> str {
        return drive(s, outputs)[0];
    }
    return run_it;
}

test "a run the Orchestrator finishes is normal, and its summary is the run's" {
    stubs = Stubs();
    stubs.install();
    try {
        outcome = daily_run(team(), RUN_DAY, scripted(full_script), RunLimits());
    } finally {
        stubs.restore();
    }
    assert outcome.status == RunStatus.NORMAL;
    assert outcome.run is not None and outcome.run.summary == "Two buys on strong panels.";
}

test "an Orchestrator whose model fails hands the run to the fallback" {
    stubs = Stubs();
    stubs.install();
    try {
        outcome = daily_run(team(), RUN_DAY, scripted(lambda (_s: RunSession) { [MockError(error=ConnectionError("provider down"))]; }), RunLimits());
    } finally {
        stubs.restore();
    }
    assert outcome.status == RunStatus.FALLBACK;
    session = outcome.session;
    assert session is not None and session.submitted and len(session.analyses) == 2;
    assert any(a.startswith("orchestrator error: ConnectionError") for a in session.actions);
}
