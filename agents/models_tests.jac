"""LimitedModel against a local fake OpenRouter: every request is limited, counted, and
retried or rerouted the way TDD §12 says. No network and no API key."""
import os;
import re;
import time;
import from pathlib { Path }
import from agents.models {
    KILL_SWITCH_ENV,
    LIMITER,
    LimitedModel,
    ModelsDisabledError,
    PRIMARY_MODEL,
    RequestLimiter,
    arbiter_llm,
    orchestrator_llm,
    research_llm,
    retry_llm,
    specialist_llm
}
import from models.agents { Stance, Vote }
import from tests.fakes.openrouter { FakeOpenRouter }

glob VOTE_JSON: str = '{"stance": "BUY", "confidence": 0.7, "horizon_days": 10, "rationale": "r", "cited_evidence": [0]}';
glob PROVIDER_PRIMARY: str = "qwen/qwen3.8-27b:free";
glob PROVIDER_FALLBACK: str = "openrouter/free";

glob fake: FakeOpenRouter = FakeOpenRouter();
glob test_limiter: RequestLimiter = RequestLimiter(per_minute=60000);
glob test_llm: LimitedModel = LimitedModel(
    model_name=PRIMARY_MODEL,
    api_key="test-key",
    config={"base_url": fake.start()},
    limiter=test_limiter,
    backoff_s=0.0
);

def cast_vote(ticker: str) -> Vote by test_llm(max_output_retries=1);

"""Run one scripted call and return the vote, the requests the fake saw, and the limiter count."""
def scripted_vote(script: list[tuple[int, str]]) -> tuple[Vote, list[dict], int] {
    fake.script = script;
    fake.requests = [];
    before = test_limiter.sent;
    vote = cast_vote("AAPL");
    return (vote, fake.requests, test_limiter.sent - before);
}

test "a call goes through the limiter to the primary model at low reasoning effort" {
    (vote, sent, counted) = scripted_vote([(200, VOTE_JSON)]);
    assert vote.stance == Stance.BUY;
    assert [r["model"] for r in sent] == [PROVIDER_PRIMARY];
    assert sent[0]["reasoning"] == {"effort": "low"};
    assert counted == 1;
}

test "a parse retry is a second request, and the limiter counts it" {
    (vote, sent, counted) = scripted_vote([(200, "not json"), (200, VOTE_JSON)]);
    assert vote.confidence == 0.7;
    assert len(sent) == 2;
    assert counted == 2;
}

test "a 429 backs off and retries the primary model" {
    (vote, sent, counted) = scripted_vote([(429, ""), (200, VOTE_JSON)]);
    assert vote.horizon_days == 10;
    assert [r["model"] for r in sent] == [PROVIDER_PRIMARY, PROVIDER_PRIMARY];
    assert counted == 2;
}

test "a primary model that stays rate limited falls back to the Free Models Router" {
    (vote, sent, counted) = scripted_vote([(429, "")] * 4 + [(200, VOTE_JSON)]);
    assert vote.stance == Stance.BUY;
    assert [r["model"] for r in sent] == [PROVIDER_PRIMARY] * 4 + [PROVIDER_FALLBACK];
    assert counted == 5;
}

test "the kill switch stops calls before any request" {
    fake.script = [(200, VOTE_JSON)];
    fake.requests = [];
    before = test_limiter.sent;
    os.environ[KILL_SWITCH_ENV] = "1";
    try {
        with testraises(ModelsDisabledError) {
            cast_vote("AAPL");
        }
    } finally {
        del os.environ[KILL_SWITCH_ENV];
    }
    assert fake.requests == [];
    assert test_limiter.sent == before;
}

test "the limiter spaces requests evenly and counts them per UTC day" {
    limiter = RequestLimiter(per_minute=600);
    start = time.monotonic();
    for _ in range(5) {
        limiter.acquire();
    }
    assert time.monotonic() - start >= 0.39;
    assert limiter.sent == 5;
    assert sum(limiter.sent_by_day.values()) == 5;
}

test "a late wake-up does not let the next request go out early" {
    limiter = RequestLimiter(per_minute=600);
    real_sleep = time.sleep;
    # Oversleep by more than one 0.1 s slot, as a busy machine can.
    def late_sleep(seconds: float) {
        real_sleep(seconds + 0.25);
    }
    time.sleep = late_sleep;
    try {
        sent_at: list[float] = [];
        for _ in range(3) {
            limiter.acquire();
            sent_at.append(time.monotonic());
        }
    } finally {
        time.sleep = real_sleep;
    }
    gaps = [b - a for (a, b) in zip(sent_at, sent_at[1:])];
    assert min(gaps) >= 0.099, gaps;
}

test "every role has its own model instance and all share one limiter" {
    roles = [research_llm, specialist_llm, arbiter_llm, orchestrator_llm, retry_llm];
    assert len({id(m) for m in roles}) == len(roles);
    assert all(m.limiter is LIMITER for m in roles);
    assert LIMITER.per_minute == 18;
}

test "no agent calls the builtin llm, which bypasses the limiter" {
    root_dir = Path(__file__).resolve().parent.parent;
    offenders: list[str] = [];
    for path in root_dir.rglob("*.jac") {
        rel = path.relative_to(root_dir);
        if not path.is_file() or {".jac", "node_modules", "dist"} & set(rel.parts) {
            continue;
        }
        if re.search(r"\bby\s+llm\s*\(", path.read_text()) {
            offenders.append(str(rel));
        }
    }
    assert not offenders, f"Call a role model from agents/models.jac, not the builtin llm: {offenders}";
}
