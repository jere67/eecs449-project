"""Contract tests for the Arbiter with MockLLM standing in for the role models (TDD §14): the
one-sided authority, the decision text, the retry path, and the safe ruling. Run serially."""
import json;
import agents.arbiter as arbiter_module;
import from jaclang.byllm.lib { MockError, MockLLM, MockRawResponse }
import from agents.arbiter { Docket, Ruling, arbitrate, arguments_text }
import from agents.models { arbiter_llm, retry_llm }
import from analysis.consensus { Consensus }
import from models.agents { Domain, MacroReport, ResearchReport, RiskRegime, Specialist, Stance, Vote }
import from models.graph { TradeAction }

def vote(stance: Stance, confidence: float, rationale: str) -> Vote {
    return Vote(stance=stance, confidence=confidence, horizon_days=10, rationale=rationale, cited_evidence=[0]);
}

def docket(draft: TradeAction) -> Docket {
    return Docket(
        ticker="AAPL",
        as_of="2026-10-16",
        draft=draft,
        consensus=Consensus(score=0.42, agreement=0.73, ci_low=0.12, ci_high=0.61, specialist_scores={"fundamentals": 0.5, "news": -0.1}, samples_used=15),
        votes={
            Specialist.FUNDAMENTALS: [vote(Stance.STRONG_BUY, 0.9, "Margins expanded for four quarters."), vote(Stance.BUY, 0.5, "Cash flow is strong.")],
            Specialist.NEWS: [vote(Stance.SELL, 0.6, "A product recall is not priced in."), vote(Stance.HOLD, 0.9, "Quiet week.")]
        },
        reports={Domain.NEWS: ResearchReport(summary="A recall hit the headlines.", view=Stance.SELL, confidence=0.6, risks=["Recall costs."])},
        time_stop="2026-10-30",
        macro=MacroReport(summary="Calm market.", regime=RiskRegime.RISK_ON, confidence=0.6)
    );
}

glob TWO_RISKS: tuple[str, str] = ("A recall widens.", "Valuation is stretched.");

def review_json(verdict: str, risks: tuple[str, ...] = TWO_RISKS, exit_condition: str = "A close below $240.") -> str {
    return json.dumps({"verdict": verdict, "reason": "The recall is not priced in.", "thesis": "Margins keep expanding.", "risks": list(risks), "exit_condition": exit_condition});
}

def with_mocks(d: Docket, primary: list[object], retry: list[object]) -> tuple[Ruling, MockLLM, MockLLM] {
    main = MockLLM(model_name="mock-arbiter", config={"outputs": primary});
    backup = MockLLM(model_name="mock-retry", config={"outputs": retry});
    saved = (arbiter_module.arbiter_llm, arbiter_module.retry_llm);
    setattr(arbiter_module, "arbiter_llm", main);
    setattr(arbiter_module, "retry_llm", backup);
    try {
        return (arbitrate(d), main, backup);
    } finally {
        setattr(arbiter_module, "arbiter_llm", saved[0]);
        setattr(arbiter_module, "retry_llm", saved[1]);
    }
}

test "a confirmed BUY keeps its action and takes the Arbiter's text" {
    (ruling, main, _) = with_mocks(docket(TradeAction.BUY), [MockRawResponse(content=review_json("CONFIRM"))], []);
    assert (ruling.action, ruling.verdict, ruling.downgrade_reason) == (TradeAction.BUY, "CONFIRM", "");
    assert ruling.thesis == "Margins keep expanding.";
    assert ruling.risks == ["A recall widens.", "Valuation is stretched."];
    assert ruling.exit_condition == "A close below $240." and ruling.model == "mock-arbiter";
    prompt = main.seen_prompts[0];
    assert "BUY: open a new position" in prompt and "2026-10-30" in prompt;
    assert "C = +0.420; A = 0.73; 90% interval for C: [+0.120, +0.610]" in prompt;
    assert "A recall hit the headlines." in prompt and "Calm market." in prompt;
}

test "a downgrade turns a BUY into NO ACTION and an ADD into HOLD, with the reason" {
    (bought, _, _) = with_mocks(docket(TradeAction.BUY), [MockRawResponse(content=review_json("DOWNGRADE"))], []);
    assert (bought.action, bought.verdict, bought.downgrade_reason) == (TradeAction.NO_ACTION, "DOWNGRADE", "The recall is not priced in.");
    (added, _, _) = with_mocks(docket(TradeAction.ADD), [MockRawResponse(content=review_json("DOWNGRADE"))], []);
    assert added.action == TradeAction.HOLD;
}

test "a downgrade of any other draft is recorded and not applied" {
    for draft in [TradeAction.SELL, TradeAction.TRIM, TradeAction.HOLD, TradeAction.NO_ACTION] {
        (ruling, _, _) = with_mocks(docket(draft), [MockRawResponse(content=review_json("DOWNGRADE"))], []);
        assert ruling.action == draft;
        assert ruling.verdict == f"DOWNGRADE (not applied to {draft.value})" and ruling.downgrade_reason == "";
    }
}

test "the Arbiter cannot upgrade: an unknown verdict fails the parse" {
    upgrade = MockRawResponse(content=review_json("UPGRADE"));
    (ruling, _, backup) = with_mocks(docket(TradeAction.NO_ACTION), [upgrade, upgrade], [upgrade, upgrade]);
    assert ruling.action == TradeAction.NO_ACTION and ruling.verdict == "unavailable";
    assert ruling.retried and len(backup.seen_prompts) == 2;
}

test "a review with one risk or no exit condition is retried with feedback" {
    one_risk = MockRawResponse(content=review_json("CONFIRM", risks=("Only one.",)));
    (ruling, main, _) = with_mocks(docket(TradeAction.BUY), [one_risk, MockRawResponse(content=review_json("CONFIRM"))], []);
    assert ruling.action == TradeAction.BUY and not ruling.retried;
    assert "risks must name the two biggest risks" in main.seen_prompts[1];
    no_exit = MockRawResponse(content=review_json("CONFIRM", exit_condition=" "));
    (retried, _, _) = with_mocks(docket(TradeAction.BUY), [no_exit, no_exit], [MockRawResponse(content=review_json("CONFIRM"))]);
    assert retried.retried and retried.model == "mock-retry" and retried.action == TradeAction.BUY;
}

test "a failed Arbiter downgrades a buy or an add and keeps any other draft" {
    down = [MockError(error=ConnectionError("provider down"))];
    (bought, _, backup) = with_mocks(docket(TradeAction.BUY), down, []);
    assert (bought.action, bought.verdict) == (TradeAction.NO_ACTION, "unavailable");
    assert bought.downgrade_reason == "Arbiter unavailable: ConnectionError: provider down";
    assert bought.error == "ConnectionError: provider down" and backup.seen_prompts == [];
    assert len(bought.risks) == 2 and "2026-10-30" in bought.exit_condition;
    (sold, _, _) = with_mocks(docket(TradeAction.SELL), [MockError(error=ConnectionError("provider down"))], []);
    assert (sold.action, sold.downgrade_reason) == (TradeAction.SELL, "");
}

test "the arguments are the strongest rationales on each side" {
    text = arguments_text(docket(TradeAction.BUY).votes);
    assert text.index("Margins expanded") < text.index("Cash flow") < text.index("Against:") < text.index("A product recall");
    # A HOLD vote argues for neither side.
    assert "Quiet week." not in text;
    assert arguments_text({}) == "For:\n- none\nAgainst:\n- none";
}

test "the Arbiter and retry roles are the shared limited instances" {
    assert arbiter_module.arbiter_llm is arbiter_llm and arbiter_module.retry_llm is retry_llm;
}
