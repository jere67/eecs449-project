"""Model instances for every agent role, behind one shared request limiter (TDD §3, §12).

byLLM has no rate limiter and does not retry a 429, and `by m(temperature=...)` overwrites
m's call params, so roles that share an instance leak settings into each other's
concurrent calls (TDD §3, rules 1 to 3). Every provider request goes through
LimitedModel.model_call_no_stream: byLLM's parse retries, transient-error retries, ReAct
iterations, and compaction summaries all call it again.
"""
import asyncio;
import os;
import threading;
import time;
import from datetime { datetime, timezone }
import from jaclang.byllm.lib { AuthenticationError, ByLLMError, ConfigurationError, Model, RateLimitError }

glob PRIMARY_MODEL: str = "openrouter/qwen/qwen3.8-27b:free";
glob FALLBACK_MODEL: str = "openrouter/openrouter/free";
glob REQUESTS_PER_MINUTE: int = 18;
glob KILL_SWITCH_ENV: str = "TRADING_AGENT_DISABLE_MODELS";

"""Raised instead of a provider request while the kill switch is on."""
obj ModelsDisabledError(Exception) {}

def models_disabled -> bool {
    return os.environ.get(KILL_SWITCH_ENV, "").strip().lower() in ("1", "true", "yes");
}

"""Paces requests evenly to at most `per_minute`, across every thread, and counts them per UTC day."""
obj RequestLimiter {
    has per_minute: int;
    has sent: int = 0,
        sent_by_day: dict[str, int] = {};
    has _lock: threading.Lock | None = None,
        _next_slot: float = 0.0;

    def postinit {
        self._lock = threading.Lock();
    }

    """Block until the next request may go out, then count it."""
    def acquire {
        with self._lock {
            now = time.monotonic();
            if self._next_slot > now {
                time.sleep(self._next_slot - now);
                # Space from the real wake-up, which can be late, not the scheduled slot.
                now = time.monotonic();
            }
            self._next_slot = now + 60.0 / self.per_minute;
            self.sent += 1;
            day = datetime.now(timezone.utc).date().isoformat();
            self.sent_by_day[day] = self.sent_by_day.get(day, 0) + 1;
        }
    }
}

glob LIMITER: RequestLimiter = RequestLimiter(per_minute=REQUESTS_PER_MINUTE);

"""A byLLM model whose every provider request passes the limiter, backs off on 429, and
falls back to the Free Models Router when the primary model stays rate limited."""
obj LimitedModel(Model) {
    has limiter: RequestLimiter = LIMITER,
        fallback_model: str = FALLBACK_MODEL,
        max_429_retries: int = 3,
        backoff_s: float = 2.0,
        reasoning_effort: str = "low";

    override def model_call_no_stream(params: dict[str, object]) -> dict[str, object] {
        if models_disabled() {
            raise ModelsDisabledError(f"{KILL_SWITCH_ENV} is set; no model requests are made");
        }
        # The free model defaults to the highest reasoning effort, which makes every call slow.
        params["extra_body"] = {
            **params.get("extra_body", {}),
            "reasoning": {"effort": self.reasoning_effort}
        };
        for attempt in range(self.max_429_retries + 1) {
            self.limiter.acquire();
            try {
                return super.model_call_no_stream(params);
            } except AuthenticationError {
                raise;
            } except ConfigurationError {
                raise;
            } except RateLimitError {
                if attempt < self.max_429_retries {
                    time.sleep(self.backoff_s * (2 ** attempt));
                }
            } except ByLLMError {
                break;
            }
        }
        params["model"] = self.fallback_model;
        self.limiter.acquire();
        return super.model_call_no_stream(params);
    }

    """Model's async path calls the provider directly, so route it through the sync one."""
    override async def model_call_no_stream_async(params: dict[str, object]) -> dict[str, object] {
        return await asyncio.to_thread(self.model_call_no_stream, params);
    }

    override def model_call_with_stream(_params: dict[str, object]) {
        raise NotImplementedError("Agents do not stream; streaming would bypass the limiter.");
    }

    override async def model_call_with_stream_async(_params: dict[str, object]) {
        raise NotImplementedError("Agents do not stream; streaming would bypass the limiter.");
    }
}

# One instance per role, so concurrent calls never share call params (TDD §3, rule 1).
glob research_llm: LimitedModel = LimitedModel(model_name=PRIMARY_MODEL);
glob specialist_llm: LimitedModel = LimitedModel(model_name=PRIMARY_MODEL);
glob arbiter_llm: LimitedModel = LimitedModel(model_name=PRIMARY_MODEL);
glob orchestrator_llm: LimitedModel = LimitedModel(model_name=PRIMARY_MODEL);
glob retry_llm: LimitedModel = LimitedModel(model_name=PRIMARY_MODEL);
