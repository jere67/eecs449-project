# Analysis exit run (#70): 20 tickers decided by the Orchestrator, and two fallback drills

Run on October 16, 2026, for the trading day of October 16, with the team's Alpaca, Finnhub, and OpenRouter keys, by `tests/runs/analysis_exit_run.jac`.
Each part wrote to its own fresh test portfolio, and every tool call was timed and logged.
All three parts spent $0.

## Answer

**The Analysis phase meets its exit criterion.**
The main run gave every one of its 20 covered tickers a valid decision, within its 600-request budget, as a normal run that the Orchestrator finished itself.
Both drills fell back to the Run Guard's fixed order, and every ticker still got a valid decision.

| Criterion | Target | Main run | Kill-switch drill | Orchestrator-down drill |
| --- | --- | --- | --- | --- |
| Status | normal; fallback in the drills | NORMAL | FALLBACK | FALLBACK |
| Covered tickers | 20 in the main run | 20 | 10 (reduced mode) | 10 (reduced mode) |
| Valid decisions | every covered ticker | 20 of 20 | 10 of 10 | 10 of 10 |
| Model requests | within the run budget | 530 of 600 | 0 | 111 of 470 |
| Fallback-model requests | - | 1 | 0 | 0 |
| Duration | under the 90-minute deadline | 44.3 min | 1.7 s | 12.9 min |
| Decisions | - | 19 NO_ACTION, 1 HOLD (flagged) | 10 HOLD (no research) | 10 NO_ACTION |

A decision is valid when it carries the Arbiter's thesis, two risks, an exit condition, and a time stop, or is a HOLD with its reason (FR-07).
The graph matched the session in every part: the main run wrote 1 Run, 20 Coverage, 64 research records (60 reports and 4 follow-ups), 278 votes, 19 consensus results, and 20 decisions.

## The three parts

**Main run.** `orchestrate` drove a standard run (K = 3) on a 20-ticker shortlist, the TDD's planning case (§12).
Preflight found 931 requests left by OpenRouter's count and none used by ours, so the run had its full 600.

**Kill-switch drill.** `TRADING_AGENT_DISABLE_MODELS=1`, so no model may be called (TDD §2, principle 6).
The Orchestrator failed on its first request, the Run Guard dispatched research (every report incomplete, with the reason), held every ticker for insufficient data, and recorded the run.
The Macro sub-agent failed safe to NEUTRAL at confidence 0.

**Orchestrator-down drill.** The driver raised before calling any tool, and the Run Guard ran research and the panel in fixed order with no follow-ups.
Both drills ran after the main run had counted 530 requests, so preflight found 470 left and ran them reduced (K = 1, a 10-ticker shortlist).
The drill asked for a 5-ticker shortlist, and reduced mode raised it to 10, which is the bug fixed below.

## Where the main run's time and requests went

| Step | Started (s) | Took (s) | Requests | Note |
| --- | --- | --- | --- | --- |
| Screen and collect | - | 70.1 | 0 | Before the loop |
| Macro brief, final answer, and recording | - | about 100 | 1 | The macro brief (RISK_OFF at 0.70) runs before the loop |
| `get_run_context` | 6 | 0 | 0 | |
| `dispatch_research`, 20 tickers × 3 domains | 9 | 351.7 | 63 | 60 reports and 3 retries, all complete |
| `request_followup` × 4 | 401 | 436.8 | 4 | NVDA news, UNH news, FAST fundamentals, CCI fundamentals, one per loop step |
| `flag_ticker` KMB | 859 | 0 | 0 | "only 8 cited claims with 12 gaps" |
| `convene_panel`, 20 tickers | 864 | 1,609.5 | 451 | 19 panels and KMB's flagged HOLD |
| `submit_decisions` | 2,480 | 0 | 0 | |
| `write_run_summary` | 2,486 | 0 | 0 | |
| Orchestrator loop | - | about 90 | 11 | Its own steps between tools, and its final answer |
| **Total** | | **2,658** | **530** | |

The panel ran at 16.8 requests a minute against the limiter's 18, so the limiter set its pace; research and follow-ups were paced by the free model's latency, as in the Research exit run.

| Requests per run (20 tickers, K = 3) | TDD estimate (§12) | Measured |
| --- | --- | --- |
| Research and macro | 61 | 64 |
| Follow-ups | up to 10 | 4 |
| Specialist samples and Arbiter | 320 | 304 |
| Extra samples near thresholds | about 20 | 0 |
| Orchestrator loop | about 30 | 11 |
| Parse and transient-error retries | about 20 | about 150 |
| **Total** | **about 460** | **530** |

## GAP-01: how many tickers a run can cover

A standard run cost 26 requests and about 2 minutes per covered ticker, plus about 12 requests and 4 minutes for the run itself.
At that rate the 600-request run budget covers about 22 tickers and the 90-minute deadline about 40, so the budget is the binding limit.
A cap of 20 covered tickers (15 screened candidates plus up to 5 open positions or wildcards) leaves about 70 requests of headroom for retries and resampling; a run that went past the budget would still finish, since a ticker whose panel no longer fits holds.
With the daily allowance of 1,000, a 530-request run leaves about 470 for on-demand reports, more than the 330 a day the global cap of 15 reports allows.
The team still has to decide whether 20 is a hard maximum (requirements §13).

## Findings

**The panel voted HOLD 86% of the time, so no ticker reached a trade.**
Of 278 valid votes, 238 were HOLD, 25 SELL, and 15 BUY; no sample chose STRONG_BUY or STRONG_SELL.
Flow voted HOLD on all 50 of its votes, and Macro and Sector was the most decisive specialist (9 BUY, 19 SELL).
The research sub-agents had already called 57 of their 60 reports HOLD, so the panel followed its evidence.
The largest |C| was 0.13 (CCI) and the largest agreement 0.33, far from the BUY threshold of 0.35, so no result counted as ambiguous and none drew extra samples.
A BUY vote's confidence averaged 0.74, so even a unanimous BUY panel would score about 0.37 and only just pass 0.35: with the current thresholds, a buy needs near-unanimity at high confidence.
This is data for GAP-04, which tunes the thresholds on history before the live test; the code follows the TDD's table.

**Retries cost about 150 requests, against about 20 estimated.**
The panel sent 451 requests for 304 base calls (285 samples and 19 reviews).
17 samples needed the retry model and 7 were dropped; the rest of the overhead is first-attempt parse failures that the second attempt fixed, Arbiter retries, and 5xx retries (the log shows a 502 from the Nvidia provider).
The limiter counts requests but not their role, so this run cannot split the overhead further; counting requests per role is the next step before tuning prompts or `max_output_retries` (#71).
The 600-request budget absorbed it.

**7 of 100 Flow samples were dropped, every one after two failed parses.**
The error text is cut at 300 characters before the second validation error, so the cause is not recorded.
Every valid Flow vote says the packet has no insider activity to weigh, which points to a vote with no citations, the case `Vote.postinit` rejects.
The drops cost no decision, since every ticker kept at least 13 of 15 samples, above the 60% minimum.

**The Orchestrator behaved as the TDD intends.**
It dispatched all research in one call, asked four follow-ups on conflicting views, flagged one ticker with thin fundamentals, convened all 20 panels in one call, and wrote an accurate summary, in 11 model steps with no refused call.
It asked its follow-ups one per loop step, which took 7.3 minutes; `request_followup` takes one ticker, so batching follow-ups like the other tools would save most of that (#72).
Its summary calls NO_ACTION "a neutral HOLD stance," which is right for tickers the team does not hold.

**The Arbiter confirmed 18 drafts and asked to downgrade one NO_ACTION**, which code recorded as not applied.

**Reduced mode raised a smaller configured shortlist to 10.**
`daily_run` used `reduced_shortlist` and `reduced_samples` as they were, so a run configured for 5 tickers covered 10 when the day ran low.
Reduced mode now takes the smaller of the reduced and standard limits, and a test covers it (#67).

**OpenRouter's request count lags our own.**
OpenRouter's `free_model_daily_requests` moved by 350 over the three parts, while the limiter counted 641 requests sent; on October 15 it did not move at all after 71 requests.
Preflight takes whichever count shows fewer requests left, so our own count set every budget here.

## Reproducing

```bash
set -a && source .env && set +a
TRADING_AGENT_RUN_ANALYSIS_EXIT=1 EXIT_OUT=/tmp/analysis-exit.json jac run --no-takeover tests/runs/analysis_exit_run.jac
```

`EXIT_PARTS` picks the parts (default `main,kill,down`) and `EXIT_RUN_DAY` the trading day.
The main run spends about 530 free-model requests, so run it on a day with the allowance to spare, and run the drills on their own (`EXIT_PARTS=kill,down`) to see them in standard mode.
