"""The Run Guard and the daily run (TDD §4, Run Guard invariants and failure handling).

`daily_run` runs one trading day's morning pipeline on a portfolio: preflight, the run claim,
collection, the macro brief, then research and analysis driven either by the Orchestrator
through a RunSession's tools or, when there is no Orchestrator or it fails, times out, aborts,
or never submits, by the same session in fixed order (the fallback). Either way the session
enforces every limit, so the Orchestrator can only choose among moves that are allowed, and
the guard makes sure every covered ticker ends with a decision before the run is recorded.

Model calls run on worker threads, which lose the graph context, so the session only holds
values; `record_run` writes everything afterwards, on the caller's thread (TDD §3, rule 6).
"""
import threading;
import time;
import from concurrent.futures { Future }
import from datetime { date, datetime }
import from zoneinfo { ZoneInfo }
import from agents.models { FALLBACK_MODEL, FREE_REQUESTS_PER_DAY, LIMITER, PRIMARY_MODEL, provider_requests_left }
import from agents.research { MacroResult, ResearchResult, macro_research, research }
import from analysis.consensus { CONSENSUS_VERSION, ConsensusConfig }
import from models.agents { Domain }
import from models.graph {
    Counted,
    Coverage,
    CoverageReason,
    Covers,
    Decided,
    Decision,
    HasMacro,
    Holds,
    MacroRecord,
    OpenedBy,
    Portfolio,
    PortfolioMode,
    Position,
    Ran,
    RequestCount,
    Researched,
    ResearchRecord,
    Run,
    RunStatus,
    TradeAction
}
import from research.alpaca { market_calendar }
import from research.briefs { macro_brief, regime_inputs }
import from research.collector { run_budget, utc_now }
import from research.screener { ScreenConfig }
import from research.sources { SOURCES_VERSION }
import from run.analysis { Holding, TickerAnalysis, analyze, record_analysis }
import from run.public { public }
import from run.research { COVERAGE_REASONS, Collection, PassConfig, briefs_for, collect_pass }
import from run.workers { NETWORK }

glob NEW_YORK: ZoneInfo = ZoneInfo("America/New_York");
glob TICKER_DOMAINS: list[Domain] = [Domain.MARKET, Domain.FUNDAMENTALS, Domain.NEWS];
glob TEAM_PORTFOLIO: str = "team";

# Tool results and stored text are capped (TDD §3, rule 12).
glob MAX_QUESTION_CHARS: int = 500;
glob MAX_REASON_CHARS: int = 300;
glob MAX_SUMMARY_CHARS: int = 2000;

"""The run's budgets and modes (TDD §4, §12). `run_requests` covers a standard 20-ticker run,
about 460 requests with retries; the day's allowance can lower it."""
obj RunLimits {
    has run_requests: int = 600,
        reduced_below: int = 500,
        followups_per_ticker: int = 2,
        react_iterations: int = 12,
        deadline_s: float = 5400.0,
        shortlist: int = 15,
        reduced_shortlist: int = 10,
        samples: int = 3,
        reduced_samples: int = 1;
}

"""What preflight found: whether the market trades on the run date, and how many free-model
requests the day has left by the app's own count and by OpenRouter's, the lower of which
sets the run's budget and whether it runs reduced."""
obj Preflight {
    has run_day: str;
    has trading_day: bool = True,
        note: str = "",
        own_used: int = 0,
        provider_left: int | None = None,
        requests_left: int = 0,
        reduced: bool = False,
        run_requests: int = 0;
}

"""Check the market calendar and the day's request allowance (TDD §12, request controls)."""
def preflight(run_day: str, portfolio: Portfolio, limits: RunLimits = RunLimits()) -> Preflight {
    found = Preflight(run_day=run_day);
    try {
        found.trading_day = run_day in [d.day for d in market_calendar(run_day, run_day, run_budget())];
        if not found.trading_day {
            found.note = f"{run_day} is not a trading day";
        }
    } except Exception as e {
        found.trading_day = date.fromisoformat(run_day).weekday() < 5;
        found.note = f"market calendar unavailable, so weekdays count as trading days ({type(e).__name__}: {str(e)[:200]})";
    }
    today = utc_now().date().isoformat();
    found.own_used = max(stored_requests(portfolio, today), LIMITER.sent_by_day.get(today, 0));
    found.provider_left = provider_requests_left();
    left = FREE_REQUESTS_PER_DAY - found.own_used;
    found.requests_left = max(0, min(left, found.provider_left) if found.provider_left is not None else left);
    found.reduced = found.requests_left < limits.reduced_below;
    found.run_requests = min(limits.run_requests, found.requests_left);
    return found;
}

"""The requests the graph records for UTC day `day`."""
def stored_requests(portfolio: Portfolio, day: str) -> int {
    return sum(c.used for c in [portfolio ->:Counted:->[?:RequestCount]] if c.day == day);
}

"""Add `requests` to UTC day `day`'s count."""
def count_requests(portfolio: Portfolio, day: str, requests: int) {
    found = [c for c in [portfolio ->:Counted:->[?:RequestCount]] if c.day == day];
    if found {
        found[0].used += requests;
    } else {
        public(portfolio +>:Counted():+> RequestCount(day=day, used=requests));
    }
}

glob _CLAIM_LOCK: threading.Lock = threading.Lock();

"""Claim the run for `run_day` on `portfolio`, or None when another firing already has it, so
a duplicate scheduler tick does no work (TDD §4, idempotency)."""
def claim_run(portfolio: Portfolio, run_day: str) -> Run | None {
    with _CLAIM_LOCK {
        if any(r.run_date == run_day for r in [portfolio ->:Ran:->[?:Run]]) {
            return None;
        }
        return public(portfolio +>:Ran():+> Run(run_date=run_day, started_at=utc_now().isoformat()));
    }
}

"""The portfolio's open positions by ticker, each with the time stop its opening decision set."""
def holdings_of(portfolio: Portfolio) -> dict[str, Holding] {
    found: dict[str, Holding] = {};
    for p in [portfolio ->:Holds:->[?:Position]] {
        opened = [p ->:OpenedBy:->[?:Decision]];
        found[p.ticker] = Holding(ticker=p.ticker, time_stop=opened[0].time_stop if opened else "");
    }
    return found;
}

"""One run's state, and the tools that change it (TDD §4, Orchestrator tools). Every tool
checks its limits and answers with a short plain-text result; a refused move changes nothing
and says why. The Orchestrator calls these through byLLM, and the fallback calls them in
fixed order, so both paths obey the same rules."""
obj RunSession {
    has run_day: str,
        collection: Collection,
        holdings: dict[str, Holding],
        config: ConsensusConfig,
        limits: RunLimits,
        run_requests: int;
    has macro: MacroResult | None = None,
        latest: dict[str, dict[Domain, ResearchResult]] = {},
        history: dict[str, list[tuple[ResearchResult, str]]] = {},
        followups: dict[str, int] = {},
        flags: dict[str, str] = {},
        analyses: dict[str, TickerAnalysis] = {},
        submitted: bool = False,
        summary: str = "",
        actions: list[str] = [],
        started: float = 0.0,
        requests_at_start: int = 0;
    has _lock: threading.RLock | None = None;

    def postinit {
        self._lock = threading.RLock();
        self.started = time.monotonic();
        self.requests_at_start = LIMITER.sent;
    }

    def tickers -> list[str] {
        return self.collection.shortlist.symbols();
    }

    def requests_used -> int {
        return LIMITER.sent - self.requests_at_start;
    }

    def requests_left -> int {
        return max(0, self.run_requests - self.requests_used());
    }

    """Requests one ticker's panel and Arbiter need at K samples, without retries."""
    def panel_cost -> int {
        return 5 * self.config.samples + 1;
    }

    def overdue -> bool {
        return time.monotonic() - self.started > self.limits.deadline_s;
    }

    """Run the Macro sub-agent once, before anything reads the macro brief."""
    def write_macro {
        if self.macro is None and self.requests_left() >= 1 {
            self.macro = macro_research(macro_brief(self.run_day, self.collection.macro_inputs));
        }
    }

    """Return the run's state: the date and mode, the request budget left, the macro brief,
    and each covered ticker with why it is covered and how far it has got."""
    def get_run_context -> str {
        with self._lock {
            lines = [
                f"Run date: {self.run_day}. Mode: {'reduced' if self.config.samples < self.limits.samples else 'standard'} (K = {self.config.samples}). Model requests left this run: {self.requests_left()}.",
                f"Macro: {self.macro.body.regime.value} at confidence {self.macro.body.confidence:.2f}. {_clip(self.macro.body.summary, 600)}" if self.macro is not None else "Macro: no brief.",
                "Tickers:"
            ];
            for pick in self.collection.shortlist.picks {
                lines.append(f"- {pick.symbol} ({pick.sector or 'sector unknown'}; {pick.reason.value}{'; held' if pick.symbol in self.holdings else ''}): {self._status(pick.symbol)}");
            }
            if self.submitted {
                lines.append("Decisions are submitted.");
            }
            return "\n".join(lines);
        }
    }

    """Run the named research sub-agents ("market", "fundamentals", "news") for a batch of
    tickers in parallel. Each ticker and domain runs at most once; use request_followup to ask
    again. Returns each ticker's research status."""
    def dispatch_research(tickers: list[str], domains: list[str]) -> str {
        with self._lock {
            notes: list[str] = [];
            wanted: list[Domain] = [];
            for name in domains {
                domain = _domain(name);
                if domain is None {
                    notes.append(f"{name}: not a research domain; use market, fundamentals, or news");
                } elif domain not in wanted {
                    wanted.append(domain);
                }
            }
            jobs: list[tuple[str, Domain]] = [];
            for ticker in _unique(tickers) {
                if ticker not in self.tickers() {
                    notes.append(f"{ticker}: not covered in this run");
                    continue;
                }
                for domain in wanted {
                    if domain in self.latest.get(ticker, {}) {
                        notes.append(f"{ticker} {domain.value}: already researched");
                    } else {
                        jobs.append((ticker, domain));
                    }
                }
            }
            room = self.requests_left();
            if len(jobs) > room {
                notes.extend(f"{t} {d.value}: not run, the run's request budget is spent" for (t, d) in jobs[room:]);
                jobs = jobs[:room];
            }
            pending: list[tuple[str, Domain, Future[ResearchResult]]] = [];
            for (ticker, domain) in jobs {
                inputs = self.collection.inputs_for(ticker);
                if inputs is not None {
                    pending.append((ticker, domain, NETWORK.submit(research, briefs_for(self.run_day, inputs)[domain])));
                }
            }
            for (ticker, domain, f) in pending {
                self._keep(ticker, domain, f.result(), "");
            }
            self.actions.append(f"dispatch_research: {len(pending)} reports");
            touched = _unique([t for (t, _) in jobs]);
            return "\n".join(notes + [f"{t}: {self._status(t)}" for t in touched]) or "Nothing to run.";
        }
    }

    """Re-run one research sub-agent on one ticker with a targeted question, such as how to
    square the news with the filings. At most two per ticker, only after that domain's first
    report and before the ticker's panel. Returns the new report's status and summary."""
    def request_followup(ticker: str, domain: str, question: str) -> str {
        with self._lock {
            found = _domain(domain);
            refusal = "";
            if ticker not in self.tickers() {
                refusal = f"{ticker}: not covered in this run";
            } elif found is None {
                refusal = f"{domain}: not a research domain; use market, fundamentals, or news";
            } elif found not in self.latest.get(ticker, {}) {
                refusal = f"{ticker} {found.value}: dispatch research first";
            } elif ticker in self.analyses {
                refusal = f"{ticker}: the panel has already ruled";
            } elif self.followups.get(ticker, 0) >= self.limits.followups_per_ticker {
                refusal = f"{ticker}: already had {self.limits.followups_per_ticker} follow-ups";
            } elif not question.strip() {
                refusal = "a follow-up needs a question";
            } elif self.requests_left() < 1 {
                refusal = "the run's request budget is spent";
            }
            if refusal or found is None {
                self.actions.append(f"request_followup refused: {refusal}");
                return f"Refused: {refusal}.";
            }
            inputs = self.collection.inputs_for(ticker);
            if inputs is None {
                return f"Refused: {ticker} has no collected data.";
            }
            asked = _clip(question, MAX_QUESTION_CHARS);
            self.followups[ticker] = self.followups.get(ticker, 0) + 1;
            answer = research(briefs_for(self.run_day, inputs)[found], asked);
            self._keep(ticker, found, answer, asked);
            self.actions.append(f"request_followup: {ticker} {found.value}");
            return f"{ticker} {found.value}: {_report_line(answer)}\nSummary: {_clip(answer.body.summary, 600)}";
        }
    }

    """Mark a ticker as unreliable today, with the reason. It is decided HOLD, with the reason
    logged and shown on the dashboard."""
    def flag_ticker(ticker: str, reason: str) -> str {
        with self._lock {
            if ticker not in self.tickers() {
                return f"Refused: {ticker} is not covered in this run.";
            }
            if self.submitted {
                return "Refused: decisions are already submitted.";
            }
            if not reason.strip() {
                return "Refused: a flag needs a reason.";
            }
            self.flags[ticker] = _clip(reason, MAX_REASON_CHARS);
            if ticker in self.analyses {
                self.analyses[ticker].forced_hold_reason = f"flagged by the Orchestrator: {self.flags[ticker]}";
            }
            self.actions.append(f"flag_ticker: {ticker}");
            return f"{ticker} flagged; it will be decided HOLD.";
        }
    }

    """Run the specialist panel, the consensus engine, and the Arbiter for a batch of tickers
    whose research is in. Each ticker is convened once. Returns each ticker's decision."""
    def convene_panel(tickers: list[str]) -> str {
        with self._lock {
            notes: list[str] = [];
            ready: dict[str, dict[Domain, ResearchResult]] = {};
            for ticker in _unique(tickers) {
                if ticker not in self.tickers() {
                    notes.append(f"{ticker}: not covered in this run");
                } elif ticker in self.analyses {
                    notes.append(f"{ticker}: already decided");
                } elif ticker in self.flags {
                    self.analyses[ticker] = TickerAnalysis(ticker=ticker, held=ticker in self.holdings, forced_hold_reason=f"flagged by the Orchestrator: {self.flags[ticker]}");
                    notes.append(f"{ticker}: HOLD (flagged)");
                } elif any(d not in self.latest.get(ticker, {}) for d in TICKER_DOMAINS) {
                    notes.append(f"{ticker}: dispatch market, fundamentals, and news research first");
                } else {
                    ready[ticker] = self.latest[ticker];
                }
            }
            (room, admitted) = (self.requests_left(), 0);
            for ticker in list(ready) {
                complete = all(r.complete() for r in ready[ticker].values());
                if complete and room < self.panel_cost() {
                    self.analyses[ticker] = TickerAnalysis(ticker=ticker, held=ticker in self.holdings, forced_hold_reason="the run's request budget was spent before the panel");
                    del ready[ticker];
                } elif complete {
                    room -= self.panel_cost();
                    admitted += 1;
                }
            }
            if ready {
                macro = self.macro.body if self.macro is not None else None;
                for result in analyze(self.run_day, ready, macro, self.holdings, self.collection.sessions, self.config, NETWORK) {
                    self.analyses[result.ticker] = result;
                }
            }
            self.actions.append(f"convene_panel: {admitted} panels");
            decided = [t for t in _unique(tickers) if t in self.analyses];
            return "\n".join(notes + [f"{t}: {_decision_line(self.analyses[t])}" for t in decided]) or "Nothing to convene.";
        }
    }

    """Send the run's decision set to the Action layer, once every covered ticker has a
    decision. `note` is a sentence on anything the reviewer should know."""
    def submit_decisions(note: str) -> str {
        with self._lock {
            if self.submitted {
                return "Refused: decisions are already submitted.";
            }
            missing = [t for t in self.tickers() if t not in self.analyses];
            if missing {
                return f"Refused: no decision yet for {', '.join(missing)}. Convene their panels first.";
            }
            self.submitted = True;
            self.actions.append(f"submit_decisions: {_clip(note, MAX_REASON_CHARS)}");
            counts: dict[str, int] = {};
            for t in self.tickers() {
                action = self.analyses[t].action().value;
                counts[action] = counts.get(action, 0) + 1;
            }
            return f"Submitted {len(self.tickers())} decisions: " + ", ".join(f"{n} {a}" for (a, n) in sorted(counts.items())) + ".";
        }
    }

    """Store the day's plain-English summary of the run, once."""
    def write_run_summary(text: str) -> str {
        with self._lock {
            if self.summary {
                return "Refused: the summary is already written.";
            }
            if not text.strip() {
                return "Refused: the summary is empty.";
            }
            self.summary = _clip(text, MAX_SUMMARY_CHARS);
            self.actions.append("write_run_summary");
            return "Summary stored.";
        }
    }

    """Finish every phase the run still owes, in fixed order and with no follow-ups: research
    for every ticker that lacks it, the panel for every ticker without a decision, and the
    submission (TDD §4, fallback). Never raises; a ticker it cannot decide holds."""
    def complete_in_order {
        try {
            unresearched = [t for t in self.tickers() if any(d not in self.latest.get(t, {}) for d in TICKER_DOMAINS)];
            if unresearched {
                self.dispatch_research(unresearched, [d.value for d in TICKER_DOMAINS]);
            }
            undecided = [t for t in self.tickers() if t not in self.analyses];
            if undecided {
                self.convene_panel(undecided);
            }
        } except Exception as e {
            self.actions.append(f"fallback error: {type(e).__name__}: {str(e)[:200]}");
        }
        for t in self.tickers() {
            if t not in self.analyses {
                self.analyses[t] = TickerAnalysis(ticker=t, held=t in self.holdings, forced_hold_reason="the run could not finish its research or panel");
            }
        }
        if not self.submitted {
            self.submit_decisions("submitted by the Run Guard");
        }
    }

    """Keep a research result: every result goes in the ticker's history, and a follow-up
    replaces the domain's report only when it is complete or the first one was not."""
    def _keep(ticker: str, domain: Domain, result: ResearchResult, question: str) {
        self.history.setdefault(ticker, []).append((result, question));
        current = self.latest.setdefault(ticker, {});
        if domain not in current or result.complete() or not current[domain].complete() {
            current[domain] = result;
        }
    }

    def _status(ticker: str) -> str {
        if ticker in self.analyses {
            return _decision_line(self.analyses[ticker]);
        }
        found = self.latest.get(ticker, {});
        parts = [f"{d.value} {_report_line(found[d])}" if d in found else f"{d.value} not yet researched" for d in TICKER_DOMAINS];
        if ticker in self.flags {
            parts.append(f"flagged: {self.flags[ticker]}");
        }
        if self.followups.get(ticker) {
            parts.append(f"{self.followups[ticker]} follow-ups used");
        }
        return "; ".join(parts);
    }
}

"""How a run ended. `run` is None only when another firing had already claimed the date."""
obj RunOutcome {
    has run_day: str,
        status: RunStatus;
    has run: Run | None = None,
        preflight: Preflight | None = None,
        session: RunSession | None = None,
        note: str = "";
}

"""Run the morning pipeline for `run_day` on `portfolio` and record it. `driver` is the
Orchestrator: it drives the session through its tools and returns its final summary. With no
driver, or when it raises, runs out the deadline, or ends without submitting, the session
finishes in fixed order and the run is marked fallback. Never raises once the run is
claimed: a failure is recorded on the run."""
def daily_run(
    portfolio: Portfolio,
    run_day: str,
    driver: Callable[[RunSession], str] | None = None,
    limits: RunLimits = RunLimits()
) -> RunOutcome {
    checked = preflight(run_day, portfolio, limits);
    run = claim_run(portfolio, run_day);
    if run is None {
        return RunOutcome(run_day=run_day, status=RunStatus.SKIPPED, preflight=checked, note=f"the run for {run_day} was already claimed");
    }
    if not checked.trading_day {
        _close(run, RunStatus.SKIPPED, f"Skipped: {checked.note}.");
        return RunOutcome(run_day=run_day, status=RunStatus.SKIPPED, run=run, preflight=checked, note=checked.note);
    }
    run.reduced_mode = checked.reduced;
    holdings = holdings_of(portfolio);
    pass_config = PassConfig(screen=ScreenConfig(shortlist_size=min(limits.reduced_shortlist, limits.shortlist) if checked.reduced else limits.shortlist));
    try {
        collection = collect_pass(run_day, sorted(holdings), pass_config);
    } except Exception as e {
        reason = f"collection failed: {type(e).__name__}: {str(e)[:300]}";
        hold_positions(run, holdings, reason);
        _close(run, RunStatus.FAILED, f"Failed: {reason}. Every open position holds.");
        return RunOutcome(run_day=run_day, status=RunStatus.FAILED, run=run, preflight=checked, note=reason);
    }
    config = ConsensusConfig(samples=min(limits.reduced_samples, limits.samples), extra_samples=0) if checked.reduced else ConsensusConfig(samples=limits.samples);
    session = RunSession(run_day=run_day, collection=collection, holdings=holdings, config=config, limits=limits, run_requests=checked.run_requests);
    session.write_macro();
    (status, said) = (RunStatus.FALLBACK, "");
    if driver is not None {
        try {
            said = driver(session);
            if session.submitted and not session.overdue() {
                status = RunStatus.NORMAL;
            }
        } except Exception as e {
            session.actions.append(f"orchestrator error: {type(e).__name__}: {str(e)[:300]}");
        }
    }
    session.complete_in_order();
    if not session.summary {
        session.summary = _clip(said, MAX_SUMMARY_CHARS) if said.strip() else default_summary(session, status);
    }
    record_run(portfolio, run, session, status);
    return RunOutcome(run_day=run_day, status=status, run=run, preflight=checked, session=session);
}

"""The run summary when the Orchestrator wrote none."""
def default_summary(s: RunSession, status: RunStatus) -> str {
    counts: dict[str, int] = {};
    for a in s.analyses.values() {
        counts[a.action().value] = counts.get(a.action().value, 0) + 1;
    }
    how = "the Orchestrator" if status == RunStatus.NORMAL else "the Run Guard's fixed order (fallback)";
    return f"{len(s.tickers())} tickers decided by {how}: " + ", ".join(f"{n} {a}" for (a, n) in sorted(counts.items())) + f". {s.requests_used()} model requests.";
}

"""Write a finished session under its claimed run: the run's totals, the macro record, and a
coverage per ticker with every research report, its votes, consensus, and decision, each
granted READ. Call it on the caller's thread, never on a worker thread."""
def record_run(portfolio: Portfolio, run: Run, s: RunSession, status: RunStatus) {
    finished = utc_now().isoformat();
    if s.macro is not None {
        public(run +>:HasMacro():+> MacroRecord(as_of=finished, model=s.macro.model, body=s.macro.body, inputs=regime_inputs(s.collection.macro_inputs)));
    }
    for pick in s.collection.shortlist.picks {
        inputs = s.collection.inputs_for(pick.symbol);
        cov = public(run +>:Covers():+> Coverage(
            ticker=pick.symbol,
            sector=pick.sector,
            reason=COVERAGE_REASONS[pick.reason],
            screen_score=pick.score or 0.0,
            reason_note=pick.note,
            fetch_errors=inputs.fetch_errors if inputs is not None else [],
            flag_reason=s.flags.get(pick.symbol, "")
        ));
        for (r, question) in s.history.get(pick.symbol, []) {
            public(cov +>:Researched():+> ResearchRecord(ticker=r.ticker, domain=r.domain, as_of=finished, model=r.model, body=r.body, followup_question=question));
        }
        record_analysis(cov, s.analyses[pick.symbol]);
    }
    run.model_versions = {"primary": PRIMARY_MODEL, "fallback": FALLBACK_MODEL, "sources": SOURCES_VERSION, "screen": s.collection.shortlist.version, "consensus": CONSENSUS_VERSION};
    run.model_requests = s.requests_used();
    count_requests(portfolio, utc_now().date().isoformat(), s.requests_used());
    _close(run, status, s.summary);
}

"""Decide HOLD for every open position when the run cannot research, so none is left without
a decision (FR-01)."""
def hold_positions(run: Run, holdings: dict[str, Holding], reason: str) {
    for ticker in sorted(holdings) {
        cov = public(run +>:Covers():+> Coverage(ticker=ticker, sector="", reason=CoverageReason.HELD, reason_note="open position"));
        public(cov +>:Decided():+> Decision(ticker=ticker, action=TradeAction.HOLD, conviction=0.0, thesis=f"No panel decision: {reason}.", forced_hold_reason=reason));
    }
}

def _close(run: Run, status: RunStatus, summary: str) {
    run.status = status;
    run.summary = summary;
    run.finished_at = utc_now().isoformat();
}

"""The team portfolio on root.shared, created in insight mode on first use: until the Action
layer trades (#29), decisions are published, not executed. Its starting balance is set when
the paper account is connected (GAP-09)."""
def team_portfolio -> Portfolio {
    for p in [root.shared -->[?:Portfolio]] {
        if p.name == TEAM_PORTFOLIO {
            return p;
        }
    }
    return public(root.shared ++> Portfolio(name=TEAM_PORTFOLIO, mode=PortfolioMode.INSIGHT, starting_cash=0.0, opened_at=utc_now().isoformat()));
}

"""Today's date in New York, the trading date a morning run decides."""
def trading_date_now -> str {
    return datetime.now(NEW_YORK).date().isoformat();
}

def _domain(name: str) -> Domain | None {
    for d in TICKER_DOMAINS {
        if name.strip().lower() == d.value {
            return d;
        }
    }
    return None;
}

def _report_line(r: ResearchResult) -> str {
    if not r.complete() {
        return f"incomplete ({_clip(r.error or 'no cited claims', 120)})";
    }
    return f"complete ({r.cited} cited claims, view {r.body.view.value} at {r.body.confidence:.2f}, {len(r.body.data_gaps)} gaps)";
}

def _decision_line(a: TickerAnalysis) -> str {
    if a.forced_hold_reason {
        return f"HOLD ({a.forced_hold_reason})";
    }
    c = a.consensus;
    stats = f"C {c.score:+.2f}, A {c.agreement:.2f}, interval [{c.ci_low:+.2f}, {c.ci_high:+.2f}]" if c is not None else "no consensus";
    verdict = a.ruling.verdict if a.ruling is not None else "no review";
    return f"{a.action().value} (draft {a.draft.value}; {stats}; conviction {a.conviction():.2f}; Arbiter {verdict})";
}

def _unique(items: list[str]) -> list[str] {
    seen: set[str] = set();
    kept: list[str] = [];
    for item in items {
        key = item.strip().upper();
        if key and key not in seen {
            seen.add(key);
            kept.append(key);
        }
    }
    return kept;
}

def _clip(text: str, limit: int) -> str {
    text = " ".join(text.split());
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…";
}
