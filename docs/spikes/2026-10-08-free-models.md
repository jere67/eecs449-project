# Spike #12: free models, typed outputs, and the tool loop on OpenRouter

Run on October 8, 2026, with the team's OpenRouter key, by `tests/spikes/model_spike.jac`.
It used 115 requests of the 1,000-a-day free allowance and spent $0.

## Answer

**The TDD's model is gone, and the replacement is Nemotron 3 Super.**
`qwen/qwen3.8-27b:free` has left OpenRouter's free list: its endpoint listing is empty, and only the paid `qwen/qwen3.8-27b` remains.
`nvidia/nemotron-3-super-120b-a12b:free` is now the primary model, and `dots-studio/dots-3-note-preview:free` the fallback, in `agents/models.jac` and `jac.toml`.
The Free Models Router is no longer the fallback, because it sent a plain prompt to a content-safety classifier.

| Question | Finding |
| --- | --- |
| 1. Valid `ResearchReport` and `Vote` objects, validation failures under 5%? | Nemotron 3 Super: 12 of 12 valid on the first request (0% failures). The runner-up needed a parse retry on 5 of 12 (42% on the first attempt, 0% after one retry). |
| 2. Does the batched tool loop finish within `max_react_iterations`, and does `ABORT_WITH_SUMMARY` stop it? | Yes and yes. Every model that answered read all three tickers in one batched call and finished in 2 to 4 requests against a cap of 6. The hook stopped every loop at its third iteration. |
| 3. Does the low reasoning effort pass through, and what is the latency? | Every model accepted `reasoning.effort`; on a one-line arithmetic prompt, low and high used about the same reasoning tokens, so the setting's effect is unmeasured. Nemotron 3 Super's median request took 10 s, the 90th percentile 79 s, and the slowest 153 s. |
| 4. Is the free list or provider policy different from TDD §12? | Yes, in four ways; see below. |

## What changed since TDD §12 was written

- **The model left the free list.** Qwen3.8 27B, the free model with the highest benchmark scores on October 3, now has no free endpoint.
- **Free-priced is not free.** `inclusionai/ling-3.1-flash` is priced at $0 and scores highest of all (Artificial Analysis intelligence index 41.1), but it has no `:free` variant, and the team key's $0 credit limit refuses it ("Key limit exceeded").
  The key's limit is a good guard against paid usage and should stay at $0.
- **Some free models are app-only.** Both Inkling `:free` models answer "only available on agentic harnesses" to direct API calls.
- **The Free Models Router is not a safe fallback.** Asked a plain question, `openrouter/free` routed to `nvidia/nemotron-3.5-content-safety:free`, which replied "User Safety: safe".
  byLLM's typed calls send a JSON schema, which may narrow the router's choice, but a fallback that can land on a classifier fails silently.

## Candidates

All 19 free models were listed on October 8; each was sent one short prompt, and the four strongest that answered ran the full spike.

| Model | Valid typed outputs | First-try parse failures | Provider errors | Median / 90th pct / max latency | Notes |
| --- | --- | --- | --- | --- | --- |
| **nvidia/nemotron-3-super-120b-a12b:free** | **12 / 12** | **0** | **0** | 10 s / 79 s / 153 s | Chosen as primary; AA intelligence index 12.8 |
| dots-studio/dots-3-note-preview:free | 12 / 12 | 5 | 0 | 16 s / 39 s / 55 s | Fallback; free until 2026-12-31; no AA score |
| nvidia/nemotron-3-ultra-550b-a55b:free | 9 / 12 | 0 | 14 ("Service temporarily overloaded") | 14 s / 50 s / 95 s | Strongest answering model (AA 22.9), but 43% uptime |
| apodex/apodex-1.1-mini:free | 0 / 12 | - | 12 | 4 s / 7 s / 13 s | Refuses byLLM's `json_schema` response format |
| google/gemma-4-31b-it:free, gemma-4-26b-a4b-it:free, poolside/laguna-xs-2.1:free | - | - | 429 upstream | - | Rate-limited at their provider |
| thinkingmachines/inkling:free, inkling-small:free | - | - | 403 | - | App-only |
| inclusionai/ling-3.1-flash | - | - | 403 | - | Not a `:free` variant |

The weak benchmark score of the chosen model is the cost of reliability: Nemotron 3 Super is the only candidate that returned every object on the first request with no provider errors.
The research and specialist prompts are small and typed, which suits it; the evaluation harness should still compare its votes with the runner-up's before launch.

## Tool loop details

The spike's Orchestrator stand-in had two tools, `read_reports(tickers)` and `ask_research(ticker, domain, question)`, and was told to read every report in one call and ask at most two follow-ups where domains disagree.

- Every model that answered batched all three tickers into one `read_reports` call and returned exactly the two expected follow-ups (NVDA fundamentals, XOM market).
- Nemotron 3 Super wrote the follow-ups straight into its plan without calling `ask_research`, which is fine for planning but means a prompt that needs the answers must say so.
- With `on_iteration` returning `ABORT_WITH_SUMMARY` after iteration 2, every loop stopped at 3 requests, as documented.
  **The summary ignores the task's limits:** each model's final plan listed 9 to 12 follow-ups after being told at most two.
  The Orchestrator must clamp follow-ups, wildcards, and every other count in code after the loop, never trust the model's count.
- No run reached `max_react_iterations`, so byLLM's forced final answer, which sends `tool_choice` naming `finish_tool`, is untested on these models.

## Consequences for the design

- **Timeouts.** A 153 s request means a per-request timeout near 180 s, and a run's wall time depends more on the 18-a-minute limiter than on latency, since requests run concurrently.
- **Fallback lifetime.** The fallback is a preview listed until 2026-12-31; the team re-checks the free list before Pitch Week and Launch Week, as TDD §12 already plans, and reruns this spike on any change.
- **Rerunning the spike.** `TRADING_AGENT_RUN_SPIKE=1 SPIKE_MODELS=<ids> SPIKE_SAMPLES=<n> SPIKE_OUT=<file> jac run --no-takeover tests/spikes/model_spike.jac`, with the keys exported.
  The guard matters: `jac test` runs every module's entry block.
