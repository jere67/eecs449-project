"""Contracts for the agent output types, run through byLLM's real parser with MockLLM."""
import from jaclang.byllm.lib { MockLLM, MockRawResponse }
import from models.agents {
    Evidence,
    ResearchReport,
    STANCE_SCORE,
    Stance,
    Vote
}

glob VALID_VOTE: str = '{"stance": "BUY", "confidence": 0.7, "horizon_days": 10, "rationale": "Margins are expanding.", "cited_evidence": [0]}';
glob BAD_CONFIDENCE_VOTE: str = '{"stance": "SELL", "confidence": 1.5, "horizon_days": 10, "rationale": "Guidance was cut.", "cited_evidence": [0]}';
glob UNCITED_REPORT: str = '{"summary": "Revenue grew.", "view": "BUY", "confidence": 0.6, "evidence": [{"claim": "Revenue grew 12%.", "source_url": "the 10-Q", "published": "2026-10-01"}]}';
glob CITED_REPORT: str = '{"summary": "Revenue grew.", "view": "BUY", "confidence": 0.6, "evidence": [{"claim": "Revenue grew 12%.", "source_url": "https://www.sec.gov/x", "published": "2026-10-01"}]}';

glob string_vote_llm: MockLLM = MockLLM(
    model_name="mockllm", config={"outputs": [MockRawResponse(content=VALID_VOTE)]}
);
glob retry_vote_llm: MockLLM = MockLLM(
    model_name="mockllm",
    config={"outputs": [MockRawResponse(content=BAD_CONFIDENCE_VOTE), MockRawResponse(content=VALID_VOTE)]}
);
glob retry_report_llm: MockLLM = MockLLM(
    model_name="mockllm",
    config={"outputs": [MockRawResponse(content=UNCITED_REPORT), MockRawResponse(content=CITED_REPORT)]}
);

def string_vote(ticker: str) -> Vote by string_vote_llm(max_output_retries=0);
def retried_vote(ticker: str) -> Vote by retry_vote_llm(max_output_retries=1);
def retried_report(ticker: str) -> ResearchReport by retry_report_llm(max_output_retries=1);

test "a stance arrives from the model as a string and parses into the enum" {
    vote = string_vote("AAPL");
    assert vote.stance == Stance.BUY;
    assert vote.stance == "BUY";
    assert vote.cited_evidence == [0];
}

test "an out-of-range confidence is sent back to the model and retried" {
    vote = retried_vote("AAPL");
    assert vote.confidence == 0.7;
    assert len(retry_vote_llm.seen_prompts) == 2;
    assert "confidence must be in [0, 1]" in retry_vote_llm.seen_prompts[1];
}

test "evidence without an http(s) source is sent back to the model and retried" {
    research = retried_report("AAPL");
    assert research.evidence[0].source_url == "https://www.sec.gov/x";
    assert len(retry_report_llm.seen_prompts) == 2;
}

test "stance scores are symmetric and span -2 to 2" {
    assert set(STANCE_SCORE.keys()) == set(Stance);
    assert sorted(STANCE_SCORE.values()) == [-2, -1, 0, 1, 2];
    assert STANCE_SCORE[Stance.STRONG_BUY] == -STANCE_SCORE[Stance.STRONG_SELL];
}

test "votes reject a horizon under one trading day" {
    with testraises(ValueError, `match="horizon_days") {
        Vote(stance=Stance.HOLD, confidence=0.5, horizon_days=0, rationale="r");
    }
}

test "evidence accepts http and https sources" {
    for url in ["https://www.sec.gov/x", "http://example.com/x"] {
        assert Evidence(claim="c", source_url=url, published="2026-10-01").source_url == url;
    }
}
