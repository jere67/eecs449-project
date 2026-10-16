"""The consensus engine (TDD §7, aggregation and decision rule): plain code that turns the
specialist panel's votes into a consensus score C, an agreement A, a bootstrap interval for
C, and a draft action. It makes no model calls.

Each vote becomes a signed score x = stance / 2 × confidence in [-1, 1], and each
specialist's score is the mean of its samples. C is the weighted mean of the specialists'
scores, and A is the weighted share of each specialist's samples that point the same way as
C; a HOLD vote (x = 0) points neither way, so it never agrees. The interval resamples whole
specialists, each with all of its samples, since a specialist's samples share one prompt and
one evidence set and are not independent.
"""
import random;
import zlib;
import from models.agents { STANCE_SCORE, Specialist, Vote }
import from models.graph { TradeAction }

# Bump when a threshold, the band, or the aggregation changes; runs store it with their
# model versions so a decision can be traced to the rule that made it.
glob CONSENSUS_VERSION: str = "2026-10-16";

"""The panel's sampling settings and the decision thresholds.

The thresholds are TDD §7's starting values, and `ambiguity_band` is proposed (GAP-04): all
are tuned on history and frozen before the forward test. A result is ambiguous when moving C,
its interval, or A by up to the band would change the draft action; such a ticker gets
`extra_samples` more samples per specialist."""
obj ConsensusConfig {
    has samples: int = 3,
        extra_samples: int = 2,
        buy_score: float = 0.35,
        buy_agreement: float = 0.6,
        sell_score: float = -0.25,
        trim_agreement: float = 0.5,
        min_success: float = 0.6,
        interval: float = 0.9,
        draws: int = 1000,
        ambiguity_band: float = 0.05;
}

"""C, A, and the interval for one ticker, with each specialist's score and weight keyed by
the specialist's value (\"fundamentals\", ...)."""
obj Consensus {
    has score: float,
        agreement: float,
        ci_low: float,
        ci_high: float;
    has specialist_scores: dict[str, float] = {},
        weights: dict[str, float] = {},
        samples_used: int = 0;

    """How strongly the panel backs its direction: |C| × A (TDD §7, decision rule)."""
    def conviction -> float {
        return abs(self.score) * self.agreement;
    }
}

"""A vote's signed score in [-1, 1]: its stance's score (-2 to +2) halved, times its
confidence."""
def signed_score(v: Vote) -> float {
    return STANCE_SCORE[v.stance] / 2 * v.confidence;
}

def sign(x: float) -> int {
    return 1 if x > 0 else (-1 if x < 0 else 0);
}

"""Aggregate the panel's valid votes, or None when no specialist has one. Specialists with no
valid vote are left out. Every specialist weighs the same in the core build; `seed` fixes the
bootstrap's draws, so the same votes always give the same interval."""
def consensus(votes: dict[Specialist, list[Vote]], seed: str, config: ConsensusConfig = ConsensusConfig()) -> Consensus | None {
    scored = {s: [signed_score(v) for v in vs] for (s, vs) in votes.items() if vs};
    if not scored {
        return None;
    }
    # Sorted, so the bootstrap draws the same specialists for the same seed whatever order
    # the votes arrived in.
    order = sorted(scored, key=lambda (s: Specialist) { s.value; });
    weights = {s: 1.0 for s in order};
    means = {s: sum(scored[s]) / len(scored[s]) for s in order};
    score = _weighted_mean([means[s] for s in order], [weights[s] for s in order]);
    direction = sign(score);
    agreeing = {s: len([x for x in scored[s] if sign(x) == direction and direction != 0]) / len(scored[s]) for s in order};
    agreement = _weighted_mean([agreeing[s] for s in order], [weights[s] for s in order]);
    (low, high) = bootstrap_interval([means[s] for s in order], [weights[s] for s in order], seed, config);
    return Consensus(
        score=score,
        agreement=agreement,
        ci_low=low,
        ci_high=high,
        specialist_scores={s.value: means[s] for s in order},
        weights={s.value: weights[s] for s in order},
        samples_used=sum(len(xs) for xs in scored.values())
    );
}

"""The `config.interval` bootstrap interval for the weighted mean of `means`, drawing whole
specialists with replacement `config.draws` times."""
def bootstrap_interval(means: list[float], weights: list[float], seed: str, config: ConsensusConfig = ConsensusConfig()) -> tuple[float, float] {
    rng = random.Random(zlib.crc32(seed.encode()));
    n = len(means);
    draws: list[float] = [];
    for _ in range(config.draws) {
        picked = [rng.randrange(n) for _ in range(n)];
        draws.append(_weighted_mean([means[i] for i in picked], [weights[i] for i in picked]));
    }
    draws.sort();
    tail = (1.0 - config.interval) / 2;
    return (quantile(draws, tail), quantile(draws, 1.0 - tail));
}

"""The `p` quantile of sorted `values`, interpolating linearly between neighbors."""
def quantile(values: list[float], p: float) -> float {
    at = p * (len(values) - 1);
    below = int(at);
    above = min(below + 1, len(values) - 1);
    return values[below] + (values[above] - values[below]) * (at - below);
}

"""The draft action for a consensus (TDD §7, decision rule). `exit_triggered` is true when a
held position's stored exit has fired, such as its time stop passing."""
def draft_action(c: Consensus, held: bool, exit_triggered: bool = False, config: ConsensusConfig = ConsensusConfig()) -> TradeAction {
    return decide(c.score, c.agreement, c.ci_low, held, exit_triggered, config);
}

def decide(score: float, agreement: float, ci_low: float, held: bool, exit_triggered: bool, config: ConsensusConfig) -> TradeAction {
    if held and (exit_triggered or score <= config.sell_score) {
        return TradeAction.SELL;
    }
    # The interval excludes zero on the buy side when its low end is above zero.
    if score >= config.buy_score and agreement >= config.buy_agreement and ci_low > 0 {
        return TradeAction.ADD if held else TradeAction.BUY;
    }
    if held and score < config.buy_score {
        return TradeAction.TRIM if agreement < config.trim_agreement else TradeAction.HOLD;
    }
    return TradeAction.NO_ACTION;
}

"""True when moving C and its interval, or A, by up to `config.ambiguity_band` would change
the draft action, so more samples could change the decision. An exit that has fired is never
ambiguous."""
def ambiguous(c: Consensus, held: bool, exit_triggered: bool = False, config: ConsensusConfig = ConsensusConfig()) -> bool {
    if exit_triggered and held {
        return False;
    }
    base = draft_action(c, held, exit_triggered, config);
    band = config.ambiguity_band;
    for d in (-band, 0.0, band) {
        for e in (-band, 0.0, band) {
            if decide(c.score + d, c.agreement + e, c.ci_low + d, held, exit_triggered, config) != base {
                return True;
            }
        }
    }
    return False;
}

"""Whether enough of the samples asked for came back valid to trust the result: fewer than
`config.min_success` forces HOLD (TDD §4, failure handling)."""
def enough_samples(valid: int, attempted: int, config: ConsensusConfig = ConsensusConfig()) -> bool {
    return attempted > 0 and valid / attempted >= config.min_success;
}

def _weighted_mean(values: list[float], weights: list[float]) -> float {
    total = sum(weights);
    return sum(v * w for (v, w) in zip(values, weights)) / total if total else 0.0;
}
