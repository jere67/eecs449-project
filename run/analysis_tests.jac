"""The Analysis phase's glue (run/analysis.jac) with MockLLM standing in for the specialist and
Arbiter models: insufficient data, a clear call, sequential sampling, a failed panel, a time
stop that fires, and the graph a finished analysis writes. No network.

Each scripted model answers every call the same way, and the pass runs on a one-worker pool,
so the order calls arrive in never matters."""
import json;
import uuid;
import from concurrent.futures { ThreadPoolExecutor }
import from jaclang.byllm.lib { MockError, MockLLM, MockRawResponse }
import agents.arbiter as arbiter_module;
import agents.specialists as specialists_module;
import from agents.research { ResearchResult }
import from analysis.consensus { ConsensusConfig }
import from models.agents { Domain, Evidence, MacroReport, ResearchReport, RiskRegime, Stance }
import from models.graph { Concluded, Coverage, CoverageReason, Decided, Portfolio, PortfolioMode, TradeAction, Voted }
import from run.analysis { Holding, TickerAnalysis, analyze, record_analysis, trading_day_after }

glob RUN_DAY: str = "2026-10-16";
glob SESSIONS: list[str] = ["2026-10-15", "2026-10-16", "2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"];
glob ONE_WORKER: ThreadPoolExecutor = ThreadPoolExecutor(max_workers=1);

def domain_report(domain: Domain) -> ResearchReport {
    claims = [Evidence(claim=f"{domain.value} fact {i}.", source_url=f"https://example.com/{domain.value}/{i}", published="2026-10-15") for i in range(2)];
    return ResearchReport(summary=f"{domain.value} looks fine.", view=Stance.BUY, confidence=0.6, evidence=claims);
}

def result(ticker: str, domain: Domain, ok: bool = True) -> ResearchResult {
    return ResearchResult(ticker=ticker, domain=domain, body=domain_report(domain), model="mock", ok=ok, cited=2 if ok else 0);
}

def research(ticker: str, failed: tuple[Domain, ...] = ()) -> dict[Domain, ResearchResult] {
    return {d: result(ticker, d, ok=d not in failed) for d in [Domain.MARKET, Domain.FUNDAMENTALS, Domain.NEWS]};
}

def macro -> MacroReport {
    return MacroReport(summary="Calm market.", regime=RiskRegime.NEUTRAL, confidence=0.5, evidence=[Evidence(claim="SPY rose.", source_url="https://example.com/spy", published="2026-10-15")]);
}

def vote_json(stance: str, confidence: float, horizon: int = 8) -> str {
    return json.dumps({"stance": stance, "confidence": confidence, "horizon_days": horizon, "rationale": "Because.", "cited_evidence": [1]});
}

def review_json(verdict: str = "CONFIRM") -> str {
    return json.dumps({"verdict": verdict, "reason": "Fine.", "thesis": "Strong on every count.", "risks": ["Valuation.", "Rates."], "exit_condition": "A close below the 50-day average."});
}

"""Run `analyze` with every specialist sample answered by `vote` and every Arbiter call by
`review`. Returns the results and the two mocks."""
def run_with(research_by_ticker: dict[str, dict[Domain, ResearchResult]], vote: object, review: object, holdings: dict[str, Holding] | None = None, calls: int = 60) -> tuple[list[TickerAnalysis], MockLLM, MockLLM] {
    panel = MockLLM(model_name="mock-specialist", config={"outputs": [vote] * calls});
    judge = MockLLM(model_name="mock-arbiter", config={"outputs": [review] * 5});
    saved = (specialists_module.specialist_llm, arbiter_module.arbiter_llm);
    setattr(specialists_module, "specialist_llm", panel);
    setattr(arbiter_module, "arbiter_llm", judge);
    try {
        return (analyze(RUN_DAY, research_by_ticker, macro(), holdings or {}, SESSIONS, ConsensusConfig(), ONE_WORKER), panel, judge);
    } finally {
        setattr(specialists_module, "specialist_llm", saved[0]);
        setattr(arbiter_module, "arbiter_llm", saved[1]);
    }
}

test "a ticker without complete research holds, with no model request" {
    (found, panel, judge) = run_with({"AAPL": research("AAPL", failed=(Domain.NEWS, Domain.MARKET))}, MockRawResponse(content=vote_json("BUY", 0.9)), MockRawResponse(content=review_json()));
    assert found[0].action() == TradeAction.HOLD;
    assert found[0].forced_hold_reason == "insufficient data: no complete market, news research";
    assert panel.seen_prompts == [] and judge.seen_prompts == [];
    assert found[0].time_stop == "2026-10-30";
}

test "a clear, unanimous call takes K samples from each specialist and one Arbiter review" {
    (found, panel, judge) = run_with({"AAPL": research("AAPL")}, MockRawResponse(content=vote_json("STRONG_BUY", 0.9, horizon=3)), MockRawResponse(content=review_json()));
    a = found[0];
    assert len(panel.seen_prompts) == 15 and len(judge.seen_prompts) == 1;
    assert a.consensus is not None and round(a.consensus.score, 9) == 0.9 and a.consensus.agreement == 1.0;
    assert (a.draft, a.action(), a.resampled) == (TradeAction.BUY, TradeAction.BUY, False);
    assert round(a.conviction(), 9) == 0.9;
    # Three trading days after Friday 2026-10-16.
    assert a.time_stop == "2026-10-21";
    assert "2026-10-21" in judge.seen_prompts[0];
}

test "an ambiguous result draws two more samples per specialist before the Arbiter" {
    # x = 0.375 for every vote, just above the 0.35 buy threshold.
    (found, panel, judge) = run_with({"AAPL": research("AAPL")}, MockRawResponse(content=vote_json("BUY", 0.75)), MockRawResponse(content=review_json("DOWNGRADE")));
    a = found[0];
    assert a.resampled and len(a.votes) == 25 and len(panel.seen_prompts) == 25;
    assert sorted({r.sample for r in a.votes}) == [0, 1, 2, 3, 4];
    assert (a.draft, a.action()) == (TradeAction.BUY, TradeAction.NO_ACTION);
    assert a.ruling is not None and a.ruling.downgrade_reason == "Fine.";
    assert len(judge.seen_prompts) == 1;
}

test "a panel with too few valid samples holds without asking the Arbiter" {
    (found, panel, judge) = run_with({"AAPL": research("AAPL")}, MockError(error=ConnectionError("provider down")), MockRawResponse(content=review_json()));
    a = found[0];
    assert a.forced_hold_reason == "only 0 of 15 specialist samples were valid";
    assert a.action() == TradeAction.HOLD and a.conviction() == 0.0;
    assert len(panel.seen_prompts) == 15 and judge.seen_prompts == [];
}

test "a held position whose time stop has passed is sold" {
    held = {"AAPL": Holding(ticker="AAPL", time_stop="2026-10-16"), "MSFT": Holding(ticker="MSFT", time_stop="2026-10-30")};
    (found, _, _) = run_with({"AAPL": research("AAPL"), "MSFT": research("MSFT")}, MockRawResponse(content=vote_json("STRONG_BUY", 0.9)), MockRawResponse(content=review_json()), holdings=held);
    per = {a.ticker: a for a in found};
    assert per["AAPL"].exit_triggered and per["AAPL"].action() == TradeAction.SELL;
    assert not per["MSFT"].exit_triggered and per["MSFT"].action() == TradeAction.ADD;
}

test "trading days are counted on the calendar, then on weekdays past its end" {
    assert trading_day_after(SESSIONS, RUN_DAY, 1) == "2026-10-19";
    assert trading_day_after(SESSIONS, RUN_DAY, 10) == "2026-10-30";
    # Two weekdays past Friday 2026-10-30.
    assert trading_day_after(SESSIONS, RUN_DAY, 12) == "2026-11-03";
    assert trading_day_after([], RUN_DAY, 1) == "2026-10-19";
}

test "a finished analysis writes its valid votes, consensus, and decision under the coverage" {
    (found, _, _) = run_with({"AAPL": research("AAPL"), "ZZZZ": research("ZZZZ", failed=(Domain.FUNDAMENTALS,))}, MockRawResponse(content=vote_json("STRONG_BUY", 0.9)), MockRawResponse(content=review_json()));
    team = Portfolio(name=f"test-{uuid.uuid4()}", mode=PortfolioMode.INSIGHT, starting_cash=0.0, opened_at="2026-10-16T11:30:00+00:00");
    root ++> team;
    per = {a.ticker: a for a in found};
    covered = Coverage(ticker="AAPL", sector="Information Technology", reason=CoverageReason.SCREEN);
    team ++> covered;
    made = record_analysis(covered, per["AAPL"]);
    assert len([covered ->:Voted:->]) == 15;
    concluded = [covered ->:Concluded:->][0];
    assert concluded.draft_action == TradeAction.BUY and (concluded.samples_used, concluded.samples_dropped) == (15, 0);
    assert [covered ->:Decided:->][0] == made;
    assert (made.action, made.arbiter_verdict, made.model) == (TradeAction.BUY, "CONFIRM", "mock-arbiter");
    assert made.risks == ["Valuation.", "Rates."] and made.exit_condition == "A close below the 50-day average.";
    short = Coverage(ticker="ZZZZ", sector="Energy", reason=CoverageReason.SCREEN);
    team ++> short;
    held = record_analysis(short, per["ZZZZ"]);
    assert (held.action, held.conviction) == (TradeAction.HOLD, 0.0);
    assert held.forced_hold_reason == "insufficient data: no complete fundamentals research";
    assert [short ->:Voted:->] == [] and [short ->:Concluded:->] == [];
}
