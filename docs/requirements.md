# Autonomous Trading Agent — Software Requirements Specification

**Course:** EECS 449, Fall 2026  
**Source:** Autonomous Trading Agent — Technical Design Document, Sep. 30, 2026  
**Document purpose:** Define what the software must provide and how it must behave, independently of implementation choices except where an external constraint is part of the product scope.

---

## 1. Purpose and scope

The product is an educational, paper-trading decision system for U.S. equities. It evaluates S&P 500 constituents once per trading day, gathers evidence from market, company, news, and macro information, produces one final decision per covered ticker, optionally submits approved paper trades for the team portfolio, and publishes a transparent record of the evidence and decision process.

The product has two core user-facing experiences:

1. A public view of the team portfolio, daily decisions, performance, and decision evidence.
2. An authenticated report experience that allows a signed-in user to request an analysis of an S&P 500 ticker.

The software shall not trade real money, provide personalized investment advice, perform intraday/high-frequency trading, support short selling, leverage, options, paid data feeds, paid model APIs, or model training/fine-tuning in the core release.

The requirements below separate stable requirements from unresolved items. Anything that remains undecided is listed in **Section 13 — Remaining knowledge gaps and resolution plan** rather than being silently assumed.

---

## 2. Stakeholders and user roles

| Role | Need / goal |
|---|---|
| Public viewer | Understand what the team portfolio holds, what decisions were made today, and why. |
| Signed-in user | Request and review an analysis report for any S&P 500 ticker. |
| Team operator / administrator | Monitor scheduled runs, failures, data-source health, model usage, orders, and portfolio state. |
| Evaluator / course team | Determine whether the system behaves reliably and whether the decision process adds value beyond the screening step. |
| System operator | Maintain the deployed service without exposing credentials or allowing unsafe trading behavior. |

---

## 3. User needs and goals

The following user needs are the basis for the functional requirements and user stories. Each need has at least one measurable requirement in Section 4 or 5.

| Need ID | User need / goal | Satisfied by |
|---|---|---|
| UN-01 | A viewer needs to understand the current team portfolio and its performance. | FR-11, FR-12, FR-15 |
| UN-02 | A viewer needs to understand how each trade or non-trade decision was reached, including disagreement and risk controls. | FR-08, FR-09, FR-10, FR-11, FR-12 |
| UN-03 | A signed-in user needs to obtain an analysis of any S&P 500 ticker without participating in the morning run. | FR-11, FR-13 |
| UN-04 | A user needs the analysis to be current, sourced, and explicit about missing or stale information. | FR-03, FR-04, FR-05 |
| UN-05 | The team needs daily decisions to be produced consistently even when individual data sources or model calls fail. | FR-01, FR-02, FR-04, FR-05, FR-06, FR-14 |
| UN-06 | The team needs paper trades to obey hard portfolio and execution limits regardless of an agent's recommendation. | FR-08, FR-09, FR-10 |
| UN-07 | The team needs to audit and reproduce what information, outputs, decisions, checks, and orders produced a result. | FR-05, FR-06, FR-07, FR-09, FR-11, FR-14, FR-15 |
| UN-08 | The team needs measurable evidence of reliability, decision quality, and component performance. | FR-15 and NFR-09 |

---

## 4. Functional requirements

### FR-01 — Market universe and daily coverage

**Requirement:** The system shall evaluate a defined set of S&P 500 stocks each trading day and shall never omit an existing open position from the daily decision process.

**Acceptance criteria**

- The current S&P 500 constituent list shall be refreshed at least weekly for live operation.
- Each candidate shall be checked for active/tradable status before inclusion.
- The daily screen shall select the highest-ranked eligible candidates subject to the configured sector-diversification rule.
- The default screening target shall be 15 new candidates, with all open positions appended to the covered set.
- The system may add up to three additional news/macro-driven wildcard tickers per run, and each wildcard shall have a stored reason for inclusion.
- Every covered ticker shall end the run with exactly one final `Decision` record, including cases where the correct result is HOLD or NO ACTION.
- A ticker that lacks sufficient market, fundamentals, or news evidence shall receive HOLD with the reason `insufficient data` rather than being silently omitted.

**Note:** The TDD's request-budget model also uses a 20-ticker standard configuration. The exact relationship between the 15-name screen and the maximum total covered set is unresolved and is listed in Section 13.

---

### FR-02 — Trading-day scheduling and preflight

**Requirement:** The system shall perform one morning decision run on each applicable U.S. trading day and one post-close review, while skipping or rescheduling work on market holidays and early closes.

**Acceptance criteria**

- The morning run shall begin at 7:30 a.m. Eastern Time on a normal trading day.
- The post-close review shall begin at 4:30 p.m. Eastern Time on a normal trading day.
- Before research begins, the system shall verify the market calendar, external service health, and remaining model-request budget.
- A market holiday shall result in a skipped trading run.
- An early close shall cause the execution/cancel/review schedule to be shifted so that it remains aligned with the actual market close.
- A scheduled run shall be identified by its trading date and shall be idempotent: a duplicate scheduler firing shall not create a second daily run or duplicate orders.
- The daily run shall remain within the required submission window, with an evaluation target of less than two hours from preflight to order submission.

---

### FR-03 — Market, company, news, and macro data acquisition

**Requirement:** The system shall collect sufficient free-source information to support the defined research domains.

**Required live data categories**

| Category | Required information |
|---|---|
| Market | Daily price/volume history, recent trading activity, and benchmark/sector comparisons. |
| Fundamentals and filings | Company facts, financial statements/filings, guidance, earnings information, insider transactions, and institutional holdings. |
| News and events | Recent company news, filings, scheduled events, earnings dates, and relevant catalysts. |
| Macro | Rates, inflation, growth, volatility regime, and sector-rotation information. |

**Acceptance criteria**

- Every datum passed to analysis shall carry its source URL, publication time, and fetch time.
- The system shall cache raw responses by source, symbol, and date.
- Historical bars and filings shall be retained beyond the 90-day raw-cache retention used for other raw inputs.
- News raw-cache entries shall be retained for 24 hours at minimum.
- Data older than its applicable freshness limit shall not be used as current evidence and shall be recorded as a data gap.
- Each source client shall perform retries with backoff and enforce its own rate limit.
- The system shall remain within the documented free-tier limits of all required sources.
- Research shall use only free or public sources in the core release.
- The public product shall not redistribute raw third-party data where the source's terms prohibit redistribution; it shall show derived results and links to original sources instead.

---

### FR-04 — Research generation and evidence citation

**Requirement:** For every covered ticker, the system shall produce structured research covering market/technical, fundamentals/filings, and news/events, plus one macro report shared across the run.

**Acceptance criteria**

- Each of the three per-ticker research domains shall produce one structured report when sufficient input data exists.
- The macro domain shall produce one report per morning run and make it available to every covered ticker.
- The market/technical analysis shall include, at minimum, 20-, 50-, and 200-day moving averages, RSI(14), MACD, Bollinger width, ATR(14), 52-week range position, relative strength to SPY and the relevant sector ETF, and relative volume.
- Indicators shall be calculated deterministically from collected data rather than generated as free-form model calculations.
- Every material research claim presented to downstream decision logic shall include a source citation.
- Every report shall explicitly record evidence, risks, and data gaps.
- External raw text shall be treated as untrusted information and shall not directly control downstream decision or action behavior.

---

### FR-05 — Research verification and failure-safe coverage

**Requirement:** The system shall verify research sufficiency before making a trade decision and shall fail safely when evidence or downstream processing is incomplete.

**Acceptance criteria**

- The decision stage shall not proceed for a ticker until the required research set is either verified or explicitly marked incomplete.
- The run coordinator may request no more than two targeted research follow-ups per ticker during the standard run.
- If required evidence remains insufficient after the allowed follow-ups, the ticker shall receive HOLD with an explicit reason.
- Invalid structured agent output shall be retried once with corrective feedback.
- If the retry still fails, the system shall perform one alternate recovery attempt at the same role and then record the sample/report failure if recovery fails.
- Provider timeouts, connection failures, and 5xx errors shall be retried up to two additional times before the failure is recorded.
- A failure in one agent or ticker shall not terminate the entire daily run.
- If fewer than 60% of specialist samples for a ticker succeed, the ticker shall be forced to HOLD.
- A normal run shall be marked `normal`; a run completed through the deterministic fallback path shall be marked `fallback`.

---

### FR-06 — Independent specialist analysis and consensus

**Requirement:** Each covered ticker shall receive independent judgments from five specialist perspectives: fundamentals, technicals, news/events, macro/sector, and flow/positioning.

**Acceptance criteria**

- Each specialist shall provide, for every sample, a stance in the ordered set STRONG_SELL, SELL, HOLD, BUY, STRONG_BUY.
- Each sample shall provide confidence in the closed interval [0,1].
- Each sample shall provide a trading horizon in days, a rationale, and at least one cited evidence item.
- A sample with no cited evidence shall be discarded.
- The standard configuration shall generate three samples per specialist per ticker.
- Specialist samples shall be generated independently and specialists shall not see each other's votes before consensus aggregation.
- Evidence shall be presented in a different order across repeated samples for the same specialist/ticker.
- If the consensus is in a configured ambiguous region near a decision threshold, two additional samples per specialist shall be generated.
- The consensus score shall be computed from stance and confidence as:

  `x = (stance score / 2) × confidence`, producing a value in [-1,1].

- Each specialist's score shall be the arithmetic mean of its samples.
- Core specialist weights shall be equal.
- The overall consensus score shall be the weighted mean of specialist scores.
- Agreement shall be the weighted share of specialist samples whose direction agrees with the consensus direction; HOLD samples shall not count as agreement.
- The system shall calculate a 90% consensus interval using 1,000 bootstrap draws that resample whole specialists rather than individual samples.
- The system shall store all valid votes and the resulting consensus statistics permanently.

---

### FR-07 — Decision rule and final adjudication

**Requirement:** The system shall convert consensus statistics into one draft action and shall apply a one-sided final review that may confirm or reduce, but never strengthen, the action.

**Acceptance criteria**

- Using the currently configured, pre-launch-frozen thresholds, the system shall produce one of BUY/ADD, SELL, HOLD, or NO ACTION.
- The starting decision thresholds are:
  - BUY/ADD when `C >= 0.35`, agreement `A >= 0.60`, and the 90% interval excludes zero.
  - SELL for a held ticker when `C <= -0.25` or the stored exit condition is triggered.
  - HOLD for a held ticker when `-0.25 < C < 0.35`, with a possible trim when agreement is below 0.50.
  - NO ACTION otherwise.
- Conviction shall equal `abs(C) × A`.
- The final adjudication stage shall receive the consensus statistics, leading rationales on both sides, and research reports.
- The adjudication stage may confirm a draft action or downgrade it, but may not upgrade it.
- Every final decision shall include a thesis, two largest risks, a time stop, and a price- or event-based exit condition.
- The final decision shall store any adjudication downgrade reason.

**Open-value handling:** The TDD says the numerical starting thresholds are tuned on historical data before launch. The requirements therefore require the values to be frozen before live operation, but do not invent final tuned values.

---

### FR-08 — Position sizing

**Requirement:** The system shall translate approved decisions into long-only target positions using conviction and relative volatility while respecting the configured portfolio limits.

**Acceptance criteria**

- A target weight shall be computed from conviction and agreement, inversely scaled by the ticker's 20-day realized volatility relative to the shortlist median.
- The sizing calculation shall include a configurable scaling constant whose starting value is 0.08.
- A per-position maximum shall be applied after the raw weight is calculated.
- Portfolio weights shall be proportionally reduced when aggregate gross exposure would exceed the gross-exposure limit.
- The MVP shall never create a short position.
- Shares shall be rounded down to whole shares.
- SELL shall mean exit or trim only.
- The exact tuned value of the per-position maximum, if changed from the starting value, shall be frozen before live testing.

---

### FR-09 — Deterministic risk gate

**Requirement:** Every proposed order shall be evaluated against all applicable risk rules before it can be submitted to the brokerage.

**Acceptance criteria**

| Rule | Required limit / behavior |
|---|---|
| Per-position exposure | No more than 10% of portfolio value. |
| Sector exposure | No more than 30% of portfolio value per GICS sector. |
| Gross exposure | No more than 90%; maintain at least 10% cash. |
| New positions | No more than 3 new positions per day; retain the highest-conviction three if more qualify. |
| Daily turnover | No more than 25% of portfolio value; scale down as required, with exits prioritized. |
| Drawdown breaker | When portfolio drawdown reaches 10% from peak, halt new buys; exits and protective stops remain active. |
| Market-regime cap | When SPY is below its 200-day average and VIX is above 30, cap gross exposure at 50%. |
| Earnings blackout | Reject new entries within 2 trading days before earnings and publish them as insight-only opportunities. |
| Liquidity | Any order shall be no larger than 1% of 20-day average daily volume. |
| Instrument eligibility | Reject instruments that are inactive, non-tradable, halted, or priced at $5 or less. |
| Protective stop | Every entry shall receive a protective stop at entry price minus 2 × ATR(14). |

Additional acceptance criteria:

- The executor shall reject any order that lacks a matching risk-gate approval.
- A risk check shall record every rule evaluation, the resulting approval/resize/rejection, and the rule responsible for any change.
- No model output shall be able to alter or bypass a risk-gate result.
- The number of orders submitted without a recorded matching risk-gate approval shall be zero.

---

### FR-10 — Paper-order execution and reconciliation

**Requirement:** In auto mode, the system shall execute only paper trades using the defined order and reconciliation rules.

**Acceptance criteria**

- Only the designated paper-trading environment may be used by the core product.
- Any attempt to use live brokerage endpoints shall be rejected.
- Entry/adjustment orders shall be marketable limit orders priced at the latest trade price ±0.3% and submitted during the 9:45 a.m. execution window under the normal schedule.
- Orders shall use DAY time-in-force for the MVP.
- Unfilled orders shall be canceled at 3:50 p.m. and reconsidered the next morning.
- Each order shall have a deterministic client identifier containing run date, ticker, action, and a distinct suffix when required for stop replacement.
- Re-submission shall first check for an existing order with the same client identifier; the system shall not knowingly duplicate an open order.
- Order status shall be polled during the execution window and again during the afternoon reconciliation step.
- The post-close process shall compare recorded positions with the brokerage's positions and flag drift.
- Protective stops shall be placed after an entry buy fills.
- For an add to an existing position, the system shall cancel the existing stop, execute the add, then place the replacement stop.
- For an exit or trim, the system shall cancel the existing stop before selling and shall replace a stop for any remaining shares.
- Expired protective stops shall be restored during the morning check.
- Time stops and thesis-invalidating conditions shall be converted into SELL decisions during the morning decision process.
- A brokerage rejection shall be logged, shown on the dashboard, and shall not be retried automatically.

---

### FR-11 — Insight reports and insight mode

**Requirement:** The system shall provide an insight-only representation of a decision that never places an order.

**Acceptance criteria**

- An insight card shall include ticker, action, conviction, specialist-vote breakdown, final thesis, two key risks, exit condition, and source links.
- The insight card shall be rendered from stored decision data and shall not require an additional model request.
- On-demand reports shall be available for any S&P 500 ticker.
- Reports for a ticker already covered during the same trading day shall reuse that day's stored research and decision information without repeating the morning research work.
- Reports shall be cached per ticker per trading day and shared across users.
- Each on-demand request shall be represented by a pending/ready state rather than keeping the initial HTTP request open for minutes.
- The end-to-end latency target shall be under 5 minutes at the 95th percentile for reports that require new analysis.
- A signed-in user shall be shown the number of report requests remaining for the day.
- The report quota shall be enforced per user and globally.

**Unresolved quota values:** See Section 13. The TDD proposes three new reports per user per day and uses a global daily cap of 15 new reports in request-budget planning, but the per-user value is explicitly marked proposed.

---

### FR-12 — Public dashboard and transparency

**Requirement:** The public product shall allow an anonymous viewer to inspect portfolio state, daily activity, decision evidence, and specialist performance without signing in.

**Acceptance criteria**

The public product shall provide, at minimum, these views:

| View | Required information |
|---|---|
| Portfolio | Equity curve versus SPY, Sharpe ratio, maximum drawdown, open positions, entry, P&L, stop, and thesis. |
| Today | Daily shortlist, action and conviction for each covered ticker, run status, and run summary. |
| Decision detail | Research and source trail, every valid specialist sample, consensus score/agreement/interval, final adjudication, risk checks, order, and fill. |
| Specialists | Specialist hit rate, calibration, and recent votes. |

Additional acceptance criteria:

- A viewer shall be able to follow a trade from the displayed order back to its decision, specialist evidence, and underlying sources.
- The system shall display specialist disagreement rather than only an aggregate number.
- Public pages shall read already-stored state and shall not trigger model calls.
- Public pages shall show derived analysis and source links rather than redistributing prohibited raw third-party data.
- Portfolio, Today, and Decision detail shall be usable on a phone without requiring horizontal scrolling at the team's documented supported mobile viewport.
- The product shall display a clear educational-project / simulated-money disclaimer and state that the content is not investment advice and simulated past performance does not predict future results.

---

### FR-13 — Authentication, accounts, and privacy

**Requirement:** Public portfolio information shall be accessible anonymously, while personal report history and user-specific data shall require authentication.

**Acceptance criteria**

- A user shall be able to create an account using email and password or Google sign-in, subject to the selected deployment configuration.
- Signed-in report actions shall run only in the authenticated user's context.
- A user's stored personal data shall be limited to the defined account information plus any optional connected brokerage information if that stretch goal is implemented.
- Users shall be able to delete their account and associated personal data.
- Core report history shall not be visible to another user.
- The core release shall not require users to connect a brokerage account.

**Connected-account stretch goal:** If implemented, only paper accounts may be connected; authorization state shall be validated; access tokens shall remain server-side, encrypted at rest, and deleted when the user disconnects.

---

### FR-14 — Auditability, logging, and observability

**Requirement:** Every daily run and every material decision/action step shall produce enough durable evidence to explain what happened and why.

**Acceptance criteria**

The system shall permanently retain, at minimum:

- Run date, run status, model version(s), request totals, and run summary.
- Ticker coverage, screen score, and inclusion reason.
- Research reports, evidence URLs/timestamps, risks, and data gaps.
- Every valid specialist vote and its scored outcome after its horizon elapses.
- Consensus statistics and weights used.
- Final decision, conviction, thesis, risks, exit condition, and adjudication downgrade reason.
- Every risk-check result, resize, and rejection.
- Brokerage order and fill identifiers, side, quantity, limit, status, fill price, and fill time.

The raw-cache layer shall retain source/symbol/date/fetch metadata and follow the retention policy in FR-03.

Observability acceptance criteria:

- Agent telemetry shall record caller, model, latency, status, and token information for every model invocation.
- Pipeline metrics shall include run duration and HTTP traffic metrics.
- An operator alert shall fire when a run falls back, when a collector fails twice consecutively, when an order is rejected, or when model usage exceeds 80% of the daily cap.
- The administrative interface shall expose run health, collector health, model-call latency, and remaining model budget.

---

### FR-15 — Post-close evaluation and performance measurement

**Requirement:** The system shall evaluate portfolio performance and component behavior using historical and forward paper-testing workflows.

**Acceptance criteria**

- The historical harness shall test deterministic screening, sizing, and risk-gate behavior over 2016–2026 history.
- Historical screening shall use point-in-time S&P 500 membership to avoid survivorship bias.
- The LLM/analysis pipeline shall be exercised on a reduced historical sample without exceeding the production free-model budget.
- Historical replays shall use only information available before the simulated decision time and only dates after the applicable model training cutoff.
- The forward evaluation shall compare the full system against an equal-weight shortlist and SPY buy-and-hold, starting from the same date and starting balance.
- After market close, every vote whose stated horizon has elapsed shall be scored.
- The system shall calculate at least: Sharpe ratio, maximum drawdown, excess return versus equal-weight shortlist, screen hit rate, specialist calibration, Arbiter downgrade value, run reliability, risk-gate bypass count, run latency, and model usage.
- Evaluation results shall be reported with bootstrap confidence intervals and without cherry-picked windows.

**Evaluation targets**

| Metric | Target |
|---|---|
| Sharpe ratio | Above SPY over the same evaluation window. |
| Maximum drawdown | No worse than SPY over the same evaluation window. |
| Excess return vs. equal-weight shortlist | Positive. |
| Screen hit-rate spread | Positive. |
| Specialist calibration | Within 10 percentage points. |
| Arbiter downgrade value | Negative for the hypothetical blocked trades. |
| Daily-run reliability | At least 98% of runs produce valid, complete decision sets. |
| Risk-gate bypasses | Zero. |
| Run latency | Under 2 hours from preflight to orders submitted. |
| Model usage | Within the applicable daily cap. |

These are evaluation targets, not guarantees of financial profitability.

---

### FR-16 — Failure recovery, fallback, budget protection, and kill switch

**Requirement:** The system shall fail safely under unavailable data, unavailable model services, rate limits, orchestration errors, and depleted request budgets.

**Acceptance criteria**

- Every provider request shall pass through a shared rate limiter set to no more than 18 requests per minute.
- Every request, including retries, fallback requests, parse retries, and orchestration iterations, shall count against the model-request budget.
- The system shall never exceed the provider's applicable daily request cap.
- Before the morning run, the system shall determine remaining daily capacity from both the system's own counter and provider-reported usage, using the lower remaining value.
- When fewer than 500 model requests remain for the UTC day, the system shall switch to reduced mode with one specialist sample per specialist and a 10-ticker shortlist.
- When fewer than 150 requests remain, new on-demand reports shall become cache-only.
- A provider 429 shall trigger exponential backoff up to three retries before fallback behavior.
- If the primary free model is unavailable, remains rate-limited, or leaves the available free set, the system shall use the designated free-model fallback path and alert the team.
- If the orchestrator fails, times out, or aborts, the deterministic fallback sequence shall execute without follow-up research requests.
- The fallback sequence shall still produce a decision for every covered ticker.
- The system shall provide a kill-switch mode in which the pipeline can execute without making model calls.
- A failed model call shall never cause a run to silently continue without recording the failure or deterministic default.

---

## 5. User stories and acceptance criteria

### US-01 — Follow today's decisions

**As a public viewer, I want to see today's covered stocks and decisions so that I can understand what the system is doing.**

**Acceptance criteria**

1. I can open the daily view without signing in.
2. I can see each covered ticker, its action, conviction, and run status.
3. I can open a ticker's decision detail and see the evidence-to-action trail.
4. I can distinguish a normal run from a fallback run.

### US-02 — Understand a trade

**As a public viewer, I want to understand why a position was opened, held, trimmed, or exited so that the paper portfolio is transparent.**

**Acceptance criteria**

1. I can see research sources and evidence supporting the decision.
2. I can see each specialist's valid samples and the resulting consensus statistics.
3. I can see the final thesis, risks, exit condition, and any adjudication downgrade.
4. I can see the risk checks and the resulting order/fill, when an order existed.

### US-03 — Request a ticker report

**As a signed-in user, I want to request an analysis for an S&P 500 ticker so that I can inspect a stock that was not necessarily selected for the morning run.**

**Acceptance criteria**

1. I must be signed in before submitting a new report request.
2. I can select any current S&P 500 ticker.
3. The system immediately records the request as pending rather than holding the HTTP request open for minutes.
4. The request eventually becomes ready or explicitly fails with a recorded reason.
5. The ready report contains the required insight-card fields and source links.
6. The report is returned within 5 minutes at the 95th percentile for requests requiring new analysis.
7. My remaining daily quota is visible.

### US-04 — Inspect performance

**As a public viewer or evaluator, I want to compare portfolio performance with SPY and the screen-only baseline so that I can judge whether the full process adds value.**

**Acceptance criteria**

1. The dashboard shows the team equity curve against SPY.
2. The dashboard shows Sharpe ratio and maximum drawdown.
3. The evaluation output includes the equal-weight shortlist comparison and screen hit-rate measure.
4. Performance reporting identifies the evaluation window and uses the same dates for all applicable baselines.

### US-05 — Operate safely

**As a team operator, I want orders to be subject to deterministic risk checks so that an erroneous recommendation cannot directly violate the portfolio rules.**

**Acceptance criteria**

1. Every submitted order references a successful risk check.
2. The risk gate can resize or reject an order according to every applicable rule.
3. No order is submitted when the gate has not approved it.
4. A forced HOLD or fallback decision cannot bypass the risk gate.
5. The recorded count of risk-gate bypasses remains zero.

### US-06 — Recover from outages

**As a team operator, I want the daily process to continue safely when a data source or model service fails so that one dependency failure does not stop the whole system.**

**Acceptance criteria**

1. A source failure triggers retries and then cached-data use when within freshness limits.
2. A source that remains unavailable produces an explicit data gap.
3. Model failures trigger the defined retry/fallback behavior and are logged.
4. If a ticker cannot reach sufficient specialist-sample success, it becomes HOLD rather than producing a trade.
5. If the orchestrator fails, the deterministic fallback sequence still produces complete coverage.

### US-07 — Audit a decision

**As an evaluator, I want every material decision step recorded so that I can reconstruct the result after the fact.**

**Acceptance criteria**

1. I can identify the run and ticker associated with a decision.
2. I can trace research evidence to specialist votes, consensus, final decision, risk checks, and orders/fills.
3. The record includes timestamps and source links needed to establish when information was available.
4. Historical records remain available after the live test.

---

## 6. Non-functional requirements

### NFR-01 — Reliability

- At least 98% of scheduled daily runs shall end with a valid, complete decision set.
- A single ticker, source, or agent failure shall not terminate the entire daily run.
- Duplicate scheduler firings shall not duplicate daily runs or trades.

### NFR-02 — Safety

- 100% of orders shall have a corresponding risk-gate approval.
- Risk-gate bypass count shall be zero.
- Real-money/live brokerage endpoints shall be unavailable to the core release.

### NFR-03 — Performance

- End-to-end on-demand report latency shall be under 5 minutes at the 95th percentile.
- The morning run shall target less than two hours from preflight to order submission.
- The research milestone target is a 20-ticker research pass in under 30 minutes with at least 90% of reports complete and every claim cited.
- Public pages shall not initiate model inference or other long-running analysis requests.

### NFR-04 — Capacity and cost

- Core research inputs shall use free/public data sources.
- Core model inference shall use the designated free-model capacity.
- Provider request throughput shall not exceed 18 requests per minute.
- Daily usage shall stay below the applicable account cap.
- Development and CI shall use mocks/fakes and shall not consume the production model-request budget.

### NFR-05 — Security

- API credentials shall never be committed to source control.
- GitHub secret scanning shall be enabled.
- Authentication/signing secrets shall be supplied through deployment secrets rather than shipped defaults.
- Raw third-party text shall be isolated from action-capable components.
- The executor shall reject any order without a matching risk check.
- Public API documentation shall be disabled in the production deployment before public launch.

### NFR-06 — Privacy

- Core personal data shall be limited to user email/account information and user-owned report records.
- Users shall be able to delete their account and personal data.
- User-owned records shall not be exposed to other users.
- Optional brokerage credentials/tokens, if the stretch goal is implemented, shall be encrypted at rest, inaccessible to the browser, and deleted upon disconnect.

### NFR-07 — Compliance and data-use constraints

- The system shall use only data sources whose free/public terms permit the educational, non-commercial use intended by the project.
- SEC requests shall remain below 10 requests per second and include the required declared User-Agent contact information.
- Public pages shall show required FRED attribution wherever FRED-derived values are presented.
- The product shall not redistribute prohibited raw third-party data.
- Every page and every insight card shall identify the product as an educational student project using simulated money and not investment advice.

### NFR-08 — Auditability and retention

- Decision, vote, risk-check, order, and fill records shall be retained permanently for the project.
- Raw cache records shall follow the retention rules in FR-03.
- Stored decision artifacts shall contain the information required to reconstruct the decision trail without depending on a live model call.

### NFR-09 — Testability

Automated testing shall cover, at minimum:

- Indicators and consensus calculations.
- Position sizing.
- Every risk-gate rule.
- Typed agent output validation and recovery.
- Rate limiting, 429 handling, and model fallback.
- Data collector parsing against recorded fixtures.
- Public/private endpoint smoke tests.
- End-to-end paper-trading integration with a tiny shortlist and mocked agents.
- Failure drills for source failure, model-provider failure, and orchestrator timeout.
- A property-based test shall demonstrate over thousands of randomized decision sets that the risk gate never emits a portfolio that violates its configured caps.

### NFR-10 — Usability and transparency

- Public viewers shall not need an account to inspect the team portfolio and decision trail.
- The decision detail experience shall expose disagreement among specialists rather than hiding it behind one aggregate score.
- Portfolio, Today, and Decision detail shall be usable on a supported phone viewport without horizontal scrolling.
- Every user-visible recommendation shall expose its key rationale, risks, exit condition, and sources.

---

## 7. External interfaces and constraints

These items are included because they materially constrain what can be built, even though they are not implementation-neutral internal requirements.

### 7.1 Paper-trading brokerage

The core release shall use the designated Alpaca paper-trading environment as the sole brokerage environment for automated orders. Real-money trading is explicitly outside scope.

### 7.2 Required data providers

The core design currently identifies these sources:

- Alpaca market data and news/trading-calendar services.
- SEC EDGAR.
- Finnhub free tier.
- FRED.
- S&P 500 constituent data from the identified public source(s).

The system shall comply with the limits and terms of the selected free tiers.

### 7.3 Model capacity constraint

The current design assumes a free model provider with a 20-request/minute provider limit and therefore sets an internal ceiling of 18 requests/minute. The daily account cap is currently expected to be 1,000 requests after the planned $10 credit purchase, or 50 otherwise. The purchase decision is an open project-management item.

### 7.4 Implementation choices that are not requirements

The TDD selects specific technologies and versions (including Jac 0.37.12, byLLM/LiteLLM, Postgres, Kubernetes, jac-client, and specific code organization). Those are design decisions and should remain in the TDD rather than being treated as user-facing software requirements unless the course explicitly mandates them.

---

## 8. Out of scope / non-goals for the core release

The following shall not be required for the core release:

- Real-money trading.
- Brokerage custody.
- Personalized investment advice.
- Intraday or high-frequency trading.
- Options trading.
- Short selling.
- Leverage.
- Paid data feeds.
- Paid model APIs.
- Training or fine-tuning models.
- Social/alternative-data integrations.
- Crypto trading.
- Prediction-market trading.
- User brokerage-account mirroring.
- A non-voting Critic specialist.
- Performance-based specialist weighting.
- A second model for specialist sampling.
- A single-agent comparison portfolio.
- Options/short-sale signals.
- Congressional-trade signals.
- Live committee streaming.
- Backup data providers unless a core source becomes unreliable.

Stretch features may begin only after the stock pipeline has run cleanly for two weeks, and none may reduce the safety or reliability of the core pipeline.

---

## 9. Release and milestone acceptance

The current TDD proposes the following milestones. Dates that depend on the course syllabus are provisional until the source is linked.

| Milestone | Required result |
|---|---|
| Foundations | Service health is available; a production-like model call can be made; automated tests are green. |
| Research | A standard research pass meets the under-30-minute / >=90%-complete milestone with cited claims. |
| Analysis | A full dry run produces a valid decision for every covered ticker and fallback mode passes its drill. |
| Action | The team paper portfolio trades for three consecutive days with zero risk-gate bypasses. |
| Dashboard MVP | Public Portfolio, Today, and Decision Detail views are deployed and a viewer can trace a trade back to its evidence. |
| Launch features | Authentication and on-demand reports work end-to-end; a new user can sign up and receive a report within five minutes. |
| Hardening/evaluation | Final evaluation metrics and the required presentation/report are complete. |

The TDD currently places MVP/Pitch Week at Nov. 2–6, 2026 and public launch at Nov. 16–20, 2026; these dates require confirmation against the course syllabus.

---

## 10. Traceability matrix

| User need | Primary requirements |
|---|---|
| UN-01 Portfolio visibility | FR-11, FR-12, FR-15, NFR-10 |
| UN-02 Transparent decision rationale | FR-04, FR-06, FR-07, FR-09, FR-10, FR-12, FR-14 |
| UN-03 On-demand ticker analysis | FR-11, FR-13, NFR-03 |
| UN-04 Current and sourced evidence | FR-03, FR-04, FR-05, NFR-07 |
| UN-05 Reliable daily operation | FR-01, FR-02, FR-05, FR-16, NFR-01, NFR-04 |
| UN-06 Safe paper trading | FR-08, FR-09, FR-10, NFR-02, NFR-05 |
| UN-07 Reconstructable decisions | FR-05, FR-06, FR-07, FR-09, FR-10, FR-14, NFR-08 |
| UN-08 Measurable evaluation | FR-15, NFR-09 |

---

## 11. Definition of done for a core requirement

A requirement is considered implemented only when all of the following are true:

1. The behavior is implemented in the deployed product or an automated testable component.
2. Every acceptance criterion attached to the requirement has a passing test, inspection, or documented operational demonstration.
3. Failure behavior is covered for any requirement that specifies a fallback, rejection, retry, or safe default.
4. The behavior is observable in the stored records when the requirement concerns a decision, order, risk check, or report.
5. The requirement does not depend on an unresolved value from Section 13 unless that value has been formally decided and frozen.

---

## 12. Known assumptions carried from the TDD

The following are treated as working assumptions for planning, not permanent requirements:

- The team portfolio is operated in auto mode; on-demand reports are insight-only.
- The primary live universe is S&P 500 equities.
- The system is long-only.
- The core specialist panel uses five domains and equal weights.
- The baseline specialist sample count is K=3.
- The initial sizing scale factor is 0.08.
- The initial risk limits are the values listed in FR-09.
- The public dashboard emphasizes transparency from evidence through decision to order.
- Stretch goals begin only after the stock pipeline is stable for two weeks.

Any assumption that is changed before launch shall be recorded with the final value, rationale, owner, and decision date.

---

## 13. Remaining knowledge gaps and resolution plan

This section is intentionally the only place where the requirements leave a material value or decision unresolved.

| Gap ID | Knowledge gap | Why it matters | Resolution plan | Required by |
|---|---|---|---|---|
| GAP-01 | Exact maximum daily covered-ticker count: the screen specifies 15 new candidates plus open positions/wildcards, while request-budget planning uses a 20-ticker standard run. | Affects model budget, runtime, testing, and API capacity. | Decide whether 20 is a hard maximum, a planning case, or whether open positions/wildcards may push the total above 20. Update FR-01 and request-budget tests. | Before Analysis phase begins. |
| GAP-02 | Final shortlist liquidity threshold; `$50M` 20-day average dollar volume is explicitly marked proposed. | Changes universe size and screening behavior. | Backtest candidate thresholds on 2016–2026 history, inspect resulting universe size and screen hit-rate spread, then freeze one value before live testing. | Before live paper test. |
| GAP-03 | Final screen weights `w1...w6`; equal weights are starting values and are tuned on history. | Changes which securities receive research attention. | Run the historical screening harness, compare candidate weight sets on out-of-sample periods, select one set, record the tuning method and freeze it before the forward test. | Before live paper test. |
| GAP-04 | Final consensus decision thresholds and exact definition of the "ambiguous region" that triggers two extra samples per specialist. | Determines BUY/SELL/HOLD behavior and request volume. | Tune thresholds on historical data, define the numeric ambiguity band, document both in versioned configuration, and freeze them before the live test. | Before live paper test. |
| GAP-05 | Final per-position cap if it changes from the 10% starting value. | Affects concentration and sizing. | Backtest candidate caps with the risk gate and freeze the selected cap with the other live-test parameters. | Before live paper test. |
| GAP-06 | Exact per-user daily on-demand-report quota; the TDD calls 3/user/day proposed, while a global cap of 15 new reports/day is used in budget planning. | Affects authentication behavior and model capacity. | Decide the user quota after a budget calculation using the frozen daily-run configuration; implement and load-test quota enforcement. | Before Launch Week. |
| GAP-07 | Who authorizes the one-time $10 OpenRouter credit purchase. | Determines whether the 1,000-request/day capacity is actually available. | Assign an owner and record the purchase/account decision in the project board; otherwise design and test against the 50-request/day fallback configuration. | Before Foundations exit. |
| GAP-08 | Production hosting environment and payer. | Required for public deployment and determines storage/operations work. | Compare the proposed Kubernetes option(s) with a single-VM deployment, choose one owner/payer, perform a deployment spike, and record the final environment. | Week 1 / before Dashboard MVP. |
| GAP-09 | Starting balance for the team paper account. | Needed to make performance comparisons reproducible. | Choose one starting balance before the paper forward test; record the balance and account creation timestamp and use the same starting value for all baseline portfolios. | Before forward test. |
| GAP-10 | Official course schedule source for Pitch Week, Launch Week, and Reflection Week end date. | Prevents milestone/date drift. | Add the course syllabus link to the repository/TDD and update the release dates here. | Before milestone sign-off. |
| GAP-11 | Launch-week user target; 50 users is explicitly proposed, not finalized. | Affects product/marketing acceptance. | Decide the launch target with the course/team, record it as a product KPI, and update the acceptance dashboard. | Before launch campaign starts. |
| GAP-12 | Ownership of platform, research, analysis, action/evaluation, and product areas. | Requirements need accountable owners for sign-off and defects. | Assign one primary owner per workstream and record ownership in the project board. | Before phase entry/within week 1. |
| GAP-13 | Exact supported mobile viewport and browser/device test matrix. | "Works on a phone" needs a reproducible acceptance test. | Choose a minimum viewport plus one current iOS/Safari and Android/Chrome test target and add them to the UI acceptance test. | Before Dashboard MVP. |
| GAP-14 | Exact definition of the "excess return" used to score individual specialist votes after their horizons elapse. | Affects specialist hit rate and calibration measurements. | Define the benchmark, holding period convention, and treatment of missing prices before scoring begins; implement one shared scoring function and test it on examples. | Before the first scored live votes. |
| GAP-15 | Exact freshness limits for each live data category/source. The TDD requires freshness enforcement but does not give every source a numeric limit. | Determines whether stale evidence can affect a decision. | Establish freshness policies per source/domain, validate them against provider update cadence, and version them before production use. | Before Research exit. |
| GAP-16 | Exact behavior of the paper brokerage for stop/add/exit sequencing and whether a one-triggers-other order can attach the stop at entry. | Affects execution safety. | Run the planned week-1 paper-account order-rule spike, document observed behavior, and update FR-10 tests to the verified sequence. | Before Action phase exit. |
| GAP-17 | Final free-model configuration and privacy/retention setting if the provider's free list changes. | Affects reliability, model quality, and external-data handling. | Re-check the free-model list and provider policy before Pitch Week and again before Launch Week; update the selected model/fallback configuration and rerun provider smoke tests. | Before Pitch and Launch. |

### Knowledge-gap exit rule

No unresolved gap may be used as an implicit implementation choice. When a gap is closed, the team shall update this document with the chosen value/decision, date, owner, and evidence, then update the affected acceptance tests.

---

## 14. Change control

Any proposed change to the software after requirements approval shall identify:

- The requirement(s) affected.
- The reason for the change.
- Whether the change affects user safety, model budget, data licensing, privacy, or evaluation comparability.
- Any new acceptance criteria.
- Any knowledge gap created by the change.
- The owner responsible for implementing and validating the change.

Changes to live-test parameters shall not be made during the live evaluation window unless the change is required to correct a safety defect; any such change shall be documented and separated from performance results gathered before the change.

---

## 15. Source basis

This requirements specification is derived from the **Autonomous Trading Agent — Technical Design Document**, especially its sections covering goals and success criteria, orchestration, universe selection, research inputs, stochastic consensus, action/risk/execution, product surfaces, dashboard behavior, persistence, request budgets, evaluation, security/testing, milestones, stretch goals, and open questions.

The TDD explicitly distinguishes proposed values and open questions; this document preserves those as knowledge gaps rather than presenting them as settled requirements.

The dashboard, authenticated report flow, transparency requirements, and daily data/report reuse are based on the product-surface and dashboard sections.

The risk, execution, and insight behaviors are based on the action/execution section of the TDD.

The evaluation, security, observability, testing, and milestone requirements are based on the corresponding TDD sections.

---

## 16. Release checklist

Before calling the core release complete, the team shall be able to answer **yes** to all of the following:

- [ ] Every required user need in Section 3 maps to tested functionality.
- [ ] Every FR acceptance criterion passes.
- [ ] All risk-gate rules are automated and tested.
- [ ] No order can be submitted without a risk-gate approval.
- [ ] Every covered ticker receives exactly one final decision.
- [ ] Failure paths produce logged, safe outcomes.
- [ ] Public pages expose the full decision trail without requiring sign-in.
- [ ] Signed-in users can request on-demand reports under the approved quota.
- [ ] Report latency meets the 95th-percentile target.
- [ ] All required source-use and privacy controls are in place.
- [ ] The historical harness, forward-paper evaluation, and baseline comparisons are reproducible.
- [ ] Every Section 13 knowledge gap required for the current phase has been closed and reflected in this document.

**End of requirements specification.**
