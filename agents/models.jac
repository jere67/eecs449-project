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
import from importlib { import_module }
import httpx;
import from jaclang.byllm.lib { AuthenticationError, ConfigurationError, Model, RateLimitError }

# Chosen by spike #12 (docs/spikes/2026-10-08-free-models.md): the only free model with every
# typed output valid on the first request and no provider errors. The fallback was the
# runner-up; it is a preview that OpenRouter lists until 2026-12-31. The Free Models Router
# is not a fallback: it sent a plain prompt to a content-safety classifier.
glob PRIMARY_MODEL: str = "openrouter/nvidia/nemotron-3-super-120b-a12b:free";
glob FALLBACK_MODEL: str = "openrouter/dots-studio/dots-3-note-preview:free";
glob REQUESTS_PER_MINUTE: int = 18;
# Spike #12's slowest successful request took 153 s; LiteLLM's default would wait 600 s.
glob REQUEST_TIMEOUT_S: float = 180.0;
glob KILL_SWITCH_ENV: str = "TRADING_AGENT_DISABLE_MODELS";
# The account's free-model allowance per UTC day, after its one-time $10 credit purchase
# (TDD §12).
glob FREE_REQUESTS_PER_DAY: int = 1000;
glob OPENROUTER_API_BASE: str = "https://openrouter.ai/api/v1";
glob OPENROUTER_API_BASE_ENV: str = "OPENROUTER_API_BASE";

# OpenRouter answers with the model name minus its "openrouter/" prefix, so LiteLLM's cost
# lookup after every response fails to find a provider and prints a "Provider List" banner
# three or four times before swallowing the error; a 20-ticker pass printed 213. Errors still
# raise; only the banner goes. The import is dynamic because a static `import litellm` makes
# `jac check` analyze all of LiteLLM's source, which takes minutes.
with entry {
    import_module("litellm").suppress_debug_info = True;
}

"""Raised instead of a provider request while the kill switch is on."""
obj ModelsDisabledError(Exception) {}

def models_disabled -> bool {
    return os.environ.get(KILL_SWITCH_ENV, "").strip().lower() in ("1", "true", "yes");
}

"""Paces requests evenly to at most `per_minute`, across every thread, and counts them per UTC
day, along with how many went to the fallback model."""
obj RequestLimiter {
    has per_minute: int;
    has sent: int = 0,
        fallbacks: int = 0,
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

    def note_fallback {
        with self._lock {
            self.fallbacks += 1;
        }
    }
}

glob LIMITER: RequestLimiter = RequestLimiter(per_minute=REQUESTS_PER_MINUTE);

"""Free-model requests OpenRouter reports left for the UTC day, from GET /key, or None when
there is no key or no readable answer. The research exit run saw OpenRouter's `used` lag the
real count, so the Run Guard takes the lower of this and its own count (TDD §12). This is not
a model request and does not pass the limiter."""
def provider_requests_left -> int | None {
    key = os.environ.get("OPENROUTER_API_KEY", "");
    if not key {
        return None;
    }
    base = os.environ.get(OPENROUTER_API_BASE_ENV, OPENROUTER_API_BASE).rstrip("/");
    try {
        response = httpx.get(f"{base}/key", headers={"Authorization": f"Bearer {key}"}, timeout=30);
        response.raise_for_status();
        usage = (response.json().get("data") or {}).get("free_model_daily_requests") or {};
        left = usage.get("remaining");
        return int(left) if left is not None else None;
    } except Exception {
        return None;
    }
}

"""A byLLM model whose every provider request passes the limiter, backs off on 429, times
out, and falls back to a second free model when the primary model stays rate limited, is
down, hangs, or has left the free list.

byLLM maps only 401, 429, and 404 to ByLLMError; a 5xx, an overloaded provider, a dropped
connection, or a timeout arrives as LiteLLM's own exception, so every error but an
authentication or configuration one falls back (#53)."""
obj LimitedModel(Model) {
    has limiter: RequestLimiter = LIMITER,
        fallback_model: str = FALLBACK_MODEL,
        max_429_retries: int = 3,
        backoff_s: float = 2.0,
        request_timeout_s: float = REQUEST_TIMEOUT_S,
        reasoning_effort: str = "low";

    override def model_call_no_stream(params: dict[str, object]) -> dict[str, object] {
        if models_disabled() {
            raise ModelsDisabledError(f"{KILL_SWITCH_ENV} is set; no model requests are made");
        }
        # Free reasoning models can default to a high effort, which makes every call slow; every
        # model in spike #12 accepted this setting.
        params["extra_body"] = {
            **params.get("extra_body", {}),
            "reasoning": {"effort": self.reasoning_effort}
        };
        params["timeout"] = self.request_timeout_s;
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
            } except Exception {
                break;
            }
        }
        params["model"] = self.fallback_model;
        self.limiter.note_fallback();
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
