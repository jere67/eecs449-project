# Research exit run (#27): 20 tickers, every report complete and cited

Run on October 15, 2026, for the trading day of October 15, with the team's Alpaca, Finnhub, and OpenRouter keys, by `tests/runs/research_exit_run.jac`.
SEC requests carried `SEC_USER_AGENT="trading-agent jeremymoon@umich.edu"`.
All three runs spent $0.

## Answer

**The Research phase meets its exit criterion.**
Run 3 is the result: the final code, on fresh data with the raw cache cleared.

| Criterion | Target | Run 1 (fresh, `flow`) | Run 2 (cached, own pool) | Run 3 (fresh, final code) |
| --- | --- | --- | --- | --- |
| Tickers | 20 | 20 | 20 | 20 |
| Duration | under 30 min | 22.3 min | 12.9 min | 12.3 min |
| Reports complete | at least 90% | 60 of 60 (100%) | 60 of 60 (100%) | 60 of 60 (100%) |
| Claims cited | every claim | 1,040 of 1,040 | 1,048 of 1,048 | 1,167 of 1,167 |
| Model requests | - | 71 | 69 | 69 |
| Fallback-model requests | - | 0 | 0 | 0 |
| Graph written | - | 1 Run, 20 Coverage, 60 ResearchRecord, 1 MacroRecord | same | same |

A report is complete when its sub-agent answered and at least one claim cites a source in its brief.
"Claims cited" counts claims that passed the citation check; the check removed none in any run, so no model invented a source.
The macro brief is counted in the claims but not in the 60 reports; it was complete in every run.

## The three runs

Run 1 used `flow` for collection and the sub-agents, as TDD §3 first described.
It showed that `flow`'s pool, not the model limiter, set the pace (below), so `run/research.jac` moved to its own 32-thread pool and run 2 measured the change.
Run 2 started 10 minutes after run 1 ended, so every source answered from the same-day raw cache; its collection time says nothing about the sources, and its research phase is the comparison.
Runs 1 and 2 gave the Macro sub-agent SPY and the 11 sector funds.
Run 3 added the Treasury funds SHY, IEF, TLT, and TIP and SPY's realized volatility as a regime input, and started with an empty raw cache, so every source answered live.
All three screened the same 20 tickers.

| Phase | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| Screen (503 constituents) | 30.6 s | 0.7 s (cache) | 14.2 s |
| Collect (20 tickers, calendar, CIKs) | 100.9 s | 2.9 s (cache) | 111.3 s |
| Research (60 reports and the macro brief) | 1,209.2 s | 772.0 s | 610.6 s |
| Model requests a minute during research | 3.5 | 5.4 | 6.8 |
| Report time, median / 90th percentile / max | 141 s / 354 s / 768 s | 150 s / 307 s / 772 s | 145 s / 309 s / 494 s |

Run 3 made 436 source requests, all within the run budgets: Finnhub 88 of 150, SEC archives 239 of 600, SEC data 40 of 600, Alpaca data 65 of 500, Alpaca trading 3 of 50, and Wikipedia 1 of 10.
No source failed and no ticker had a fetch error.

## Findings

**`flow`'s pool held the research phase to a third of the limiter's rate.**
`flow` runs on the runtime's default `ThreadPoolExecutor`, `min(32, cpu + 4)` threads, which is 12 on the 8-core laptop that ran it and would be 6 on a 2-vCPU server.
The total time of all 61 sub-agent calls divided by run 1's research wall time was 9.7, so about 10 calls were ever in flight, and the limiter, which allows 18 requests a minute, saw 3.5.
Network-bound calls do not need a core each, so the pass now uses a dedicated pool of 32 threads, and the deploy machine's core count no longer sets the run time.
The research phase took 772 s in run 2 and 611 s in run 3, against 1,209 s in run 1, at 5.4 and 6.8 requests a minute.
With 32 calls in flight, the limiter is still not the constraint: the free model's own latency is, and the slowest report set the phase's length on its own.

**LiteLLM printed 213 "Provider List" banners in run 1.**
OpenRouter answers with the model name without its `openrouter/` prefix, so LiteLLM's cost lookup after each response cannot find a provider; it prints a banner three or four times and swallows the error.
Requests were unaffected, but the banners buried the log.
`agents/models.jac` now sets `litellm.suppress_debug_info`, a test reproduces the lookup and fails without it, and runs 2 and 3 printed none.

**The numbers in the reports match the filings.**
NVIDIA's Fundamentals report in run 1, the one with the most surprising figures, was checked against SEC's raw XBRL facts: trailing net income $192.9 billion (120.1 + 118.0 - 45.2), operating cash flow $134.3 billion, and quarterly revenue growth of 105.9% (96.2 against 46.7) are all exact, for a fiscal year that ends in January.
Net income above operating cash flow is in NVIDIA's own filings, not an error in the trailing-year arithmetic.

**The macro call changed between runs on the same inputs.**
Run 1 called the regime RISK_ON at 0.85, and run 2 NEUTRAL at 0.55, from identical cached data at temperature 0.2.
This is why the risk gate reads `RegimeInputs`, computed in code, and not the Macro sub-agent's label (TDD §8).
In run 3, SPY closed at 769.60 against its 200-day average of 721.01, with 20-day realized volatility of 10.3%, so the regime filter would not cap exposure.

**The Macro sub-agent read the Treasury funds the right way, and overstated one point.**
It cited all four funds, and the figures it cited are the brief's: IEF fell 2.8% and TLT 4.6% over 60 days, and TIP beat IEF by 0.7%, which it read as rising yields and rising inflation expectations.
Its summary said prices fell "across the curve", but SHY was flat (+0.2% over 20 days, 0.0% over 60), so the short end held while the long end sold off.
The citation check verifies sources, not wording, so a summary can generalize past its evidence.

**Models still pack several facts into one claim.**
PSX's Market report in run 1 cited one source for one long claim holding the close, three moving averages, and the source URL repeated in the text, and in run 3 the macro brief's claims copied whole sources.
The claims are accurate, but the research prompt asks for one fact per evidence item, and the citation check only verifies the source, so a claim count overstates how much evidence such a report holds.

**Parse retries are part of the request count.**
Run 1's 61 calls made 71 requests and run 3's made 69: the extra 10 and 8 were byLLM's in-model parse retries, which succeeded without the retry model.
In run 2, one call used the retry model and still completed.

**OpenRouter's usage counter is not real time.**
`/api/v1/key` reported 0 free requests used before and after each run, so the limiter's own count is the record of model requests.

## Gaps

- **No economic releases.** The Macro sub-agent sees market prices only, so it reads rates and inflation expectations from Treasury funds and has no GDP or unemployment figures; it listed those as data gaps.
- **One machine.** All three runs used an 8-core laptop on a home connection; the deployed scheduler should log the same phase timings.

## Reproduce

```bash
set -a && source .env && set +a
TRADING_AGENT_RUN_EXIT=1 EXIT_OUT=/tmp/exit.json jac run --no-takeover tests/runs/research_exit_run.jac
```

`EXIT_RUN_DAY` sets the trading day (default: today in New York).
Move `storage/raw` aside first for a run on fresh data; otherwise sources answer from the same-day raw cache.
A pass spends about 70 of the 1,000 free-model requests a day.
