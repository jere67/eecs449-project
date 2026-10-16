"""The Analysis phase of a run (TDD §4 8:30 to 9:00 a.m., §7): the specialist panel on every
ticker with complete research, the consensus engine, two more samples per specialist where
the result is ambiguous, and the Arbiter, ending in one decision per ticker.

Model calls run on the shared network pool in flat batches, never nested, so no worker waits
on another (run/workers.jac). `analyze` only returns values; `record_analysis` writes them to
the graph afterwards, on the caller's thread (TDD §3, rule 6). A ticker that lacks complete
market, fundamentals, or news research, or whose panel returns too few valid samples, gets
HOLD with the reason and no Arbiter call, so every ticker still ends with a decision (FR-01,
FR-05).
"""
import statistics;
import from concurrent.futures { Future, ThreadPoolExecutor }
import from datetime { date, timedelta }
import from agents.arbiter { Docket, Ruling, arbitrate }
import from agents.research { ResearchResult }
import from agents.specialists { Packet, VoteResult, packet, sample_vote }
import from analysis.consensus { Consensus, ConsensusConfig, ambiguous, consensus, draft_action, enough_samples, sign, signed_score }
import from models.agents { Domain, MacroReport, Specialist, Vote }
import from models.graph { Concluded, ConsensusResult, Coverage, Decided, Decision, TradeAction, VoteRecord, Voted }
import from run.public { public }
import from run.workers { NETWORK }

# A ticker needs a complete report in each of these before the panel sees it (TDD §4, Run
# Guard invariants: coverage).
glob REQUIRED_DOMAINS: list[Domain] = [Domain.MARKET, Domain.FUNDAMENTALS, Domain.NEWS];

# The time stop when no vote gives a horizon, in trading days.
glob DEFAULT_HORIZON_DAYS: int = 10;

# Which way each action points, for the votes its time stop is drawn from.
glob ACTION_DIRECTION: dict[TradeAction, int] = {TradeAction.BUY: 1, TradeAction.ADD: 1, TradeAction.SELL: -1, TradeAction.TRIM: -1};

"""What the decision rule needs to know about a held position. `time_stop` is the trading date
its opening decision set ("" when none); the exit fires once the run date reaches it."""
obj Holding {
    has ticker: str;
    has time_stop: str = "";

    def exit_triggered(run_day: str) -> bool {
        return bool(self.time_stop) and self.time_stop <= run_day;
    }
}

"""One ticker's way through the panel, the consensus engine, and the Arbiter."""
obj TickerAnalysis {
    has ticker: str,
        held: bool;
    has exit_triggered: bool = False,
        votes: list[VoteResult] = [],
        consensus: Consensus | None = None,
        draft: TradeAction = TradeAction.NO_ACTION,
        resampled: bool = False,
        ruling: Ruling | None = None,
        forced_hold_reason: str = "",
        time_stop: str = "";

    """The valid votes by specialist."""
    def valid_votes -> dict[Specialist, list[Vote]] {
        found: dict[Specialist, list[Vote]] = {};
        for r in self.votes {
            if r.vote is not None {
                found.setdefault(r.specialist, []).append(r.vote);
            }
        }
        return found;
    }

    def valid_count -> int {
        return len([r for r in self.votes if r.valid()]);
    }

    def action -> TradeAction {
        if self.forced_hold_reason {
            return TradeAction.HOLD;
        }
        return self.ruling.action if self.ruling is not None else self.draft;
    }

    def conviction -> float {
        if self.forced_hold_reason or self.consensus is None {
            return 0.0;
        }
        return self.consensus.conviction();
    }
}

"""Decide every ticker in `research` (each ticker's results by domain), with the run's macro
report, the portfolio's holdings by ticker, and the trading sessions around `run_day` for time
stops. Never touches the graph; pass each result to `record_analysis`."""
def analyze(
    run_day: str,
    research: dict[str, dict[Domain, ResearchResult]],
    macro: MacroReport | None,
    holdings: dict[str, Holding],
    sessions: list[str],
    config: ConsensusConfig = ConsensusConfig(),
    workers: ThreadPoolExecutor = NETWORK
) -> list[TickerAnalysis] {
    results: list[TickerAnalysis] = [];
    packets: dict[str, list[Packet]] = {};
    for (ticker, found) in research.items() {
        holding = holdings.get(ticker);
        result = TickerAnalysis(ticker=ticker, held=holding is not None, exit_triggered=holding is not None and holding.exit_triggered(run_day));
        missing = [d.value for d in REQUIRED_DOMAINS if d not in found or not found[d].complete()];
        if missing {
            result.forced_hold_reason = f"insufficient data: no complete {', '.join(missing)} research";
        } else {
            reports = {d: r.body for (d, r) in found.items()};
            packets[ticker] = [packet(s, ticker, run_day, reports, macro) for s in list(Specialist)];
        }
        results.append(result);
    }
    by_ticker = {r.ticker: r for r in results};

    draw(by_ticker, packets, list(range(config.samples)), workers);
    for ticker in packets {
        conclude(by_ticker[ticker], run_day, config);
    }
    unsure = [t for t in packets if by_ticker[t].consensus is not None and not by_ticker[t].forced_hold_reason and ambiguous(by_ticker[t].consensus, by_ticker[t].held, by_ticker[t].exit_triggered, config)];
    if unsure and config.extra_samples > 0 {
        draw(by_ticker, {t: packets[t] for t in unsure}, list(range(config.samples, config.samples + config.extra_samples)), workers);
        for ticker in unsure {
            by_ticker[ticker].resampled = True;
            conclude(by_ticker[ticker], run_day, config);
        }
    }

    for result in results {
        result.time_stop = trading_day_after(sessions, run_day, horizon(result));
    }
    reviewing: list[tuple[TickerAnalysis, Future[Ruling]]] = [];
    for result in results {
        if not result.forced_hold_reason and result.consensus is not None {
            found = research[result.ticker];
            docket = Docket(
                ticker=result.ticker,
                as_of=run_day,
                draft=result.draft,
                consensus=result.consensus,
                votes=result.valid_votes(),
                reports={d: r.body for (d, r) in found.items()},
                time_stop=result.time_stop,
                macro=macro
            );
            reviewing.append((result, workers.submit(arbitrate, docket)));
        }
    }
    for (result, pending) in reviewing {
        result.ruling = pending.result();
    }
    return results;
}

"""Draw samples `samples` from every packet of every ticker in `packets`, as one flat batch,
and add the results to each ticker's votes in packet and sample order."""
def draw(by_ticker: dict[str, TickerAnalysis], packets: dict[str, list[Packet]], samples: list[int], workers: ThreadPoolExecutor) {
    pending: list[tuple[str, Future[VoteResult]]] = [];
    for (ticker, found) in packets.items() {
        for p in found {
            for k in samples {
                pending.append((ticker, workers.submit(sample_vote, p, k)));
            }
        }
    }
    for (ticker, f) in pending {
        by_ticker[ticker].votes.append(f.result());
    }
}

"""Aggregate a ticker's votes so far into its consensus and draft action, or force HOLD when
too few samples came back valid (TDD §4, failure handling)."""
def conclude(result: TickerAnalysis, run_day: str, config: ConsensusConfig) {
    (valid, attempted) = (result.valid_count(), len(result.votes));
    found = consensus(result.valid_votes(), f"{result.ticker}:{run_day}", config);
    if found is None or not enough_samples(valid, attempted, config) {
        result.consensus = found;
        result.forced_hold_reason = f"only {valid} of {attempted} specialist samples were valid";
        return;
    }
    result.consensus = found;
    result.draft = draft_action(found, result.held, result.exit_triggered, config);
}

"""The horizon in trading days for a ticker's time stop: the median horizon of the valid
votes pointing the way of its draft action, or of all its valid votes when the action has no
direction."""
def horizon(result: TickerAnalysis) -> int {
    direction = ACTION_DIRECTION.get(result.draft, 0);
    votes = [v for vs in result.valid_votes().values() for v in vs];
    if direction != 0 and not result.forced_hold_reason {
        votes = [v for v in votes if sign(signed_score(v)) == direction] or votes;
    }
    if not votes {
        return DEFAULT_HORIZON_DAYS;
    }
    return max(1, int(statistics.median_low([v.horizon_days for v in votes])));
}

"""The `n`th trading session after `run_day`, from `sessions` (ISO dates from the market
calendar), counting on weekdays past the calendar's end."""
def trading_day_after(sessions: list[str], run_day: str, n: int) -> str {
    ahead = sorted(s for s in set(sessions) if s > run_day);
    if n <= len(ahead) {
        return ahead[n - 1];
    }
    day = date.fromisoformat(ahead[-1] if ahead else run_day);
    left = n - len(ahead);
    while left > 0 {
        day += timedelta(days=1);
        if day.weekday() < 5 {
            left -= 1;
        }
    }
    return day.isoformat();
}

"""Write one ticker's valid votes, its consensus, and its decision under its coverage, each
granted READ. Call it on the caller's thread, never on a worker thread."""
def record_analysis(coverage: Coverage, result: TickerAnalysis) -> Decision {
    for r in result.votes {
        if r.vote is not None {
            public(coverage +>:Voted():+> VoteRecord(ticker=result.ticker, specialist=r.specialist, sample=r.sample, model=r.model, body=r.vote));
        }
    }
    found = result.consensus;
    if found is not None {
        public(coverage +>:Concluded():+> ConsensusResult(
            ticker=result.ticker,
            score=found.score,
            agreement=found.agreement,
            ci_low=found.ci_low,
            ci_high=found.ci_high,
            draft_action=result.draft,
            specialist_scores=found.specialist_scores,
            weights=found.weights,
            samples_used=result.valid_count(),
            samples_dropped=len(result.votes) - result.valid_count()
        ));
    }
    return public(coverage +>:Decided():+> decision(result));
}

def decision(result: TickerAnalysis) -> Decision {
    ruling = result.ruling;
    if result.forced_hold_reason or ruling is None {
        reason = result.forced_hold_reason or "the Arbiter did not rule";
        return Decision(ticker=result.ticker, action=TradeAction.HOLD, conviction=0.0, thesis=f"No panel decision: {reason}.", time_stop=result.time_stop, forced_hold_reason=reason);
    }
    return Decision(
        ticker=result.ticker,
        action=ruling.action,
        conviction=result.conviction(),
        thesis=ruling.thesis,
        risks=ruling.risks,
        exit_condition=ruling.exit_condition,
        time_stop=result.time_stop,
        downgrade_reason=ruling.downgrade_reason,
        arbiter_verdict=ruling.verdict,
        model=ruling.model
    );
}
