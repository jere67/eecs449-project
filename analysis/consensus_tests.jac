"""The consensus engine against hand-computed examples, and seeded randomized checks of the
properties every result must have."""
import math;
import random;
import from models.agents { Specialist, Stance, Vote }
import from models.graph { TradeAction }
import from analysis.consensus {
    Consensus,
    ConsensusConfig,
    ambiguous,
    bootstrap_interval,
    consensus,
    decide,
    draft_action,
    enough_samples,
    quantile,
    signed_score
}

glob CONFIG: ConsensusConfig = ConsensusConfig();

def vote(stance: Stance, confidence: float) -> Vote {
    return Vote(stance=stance, confidence=confidence, horizon_days=10, rationale="r", cited_evidence=[0]);
}

def close_to(a: float, b: float) -> bool {
    return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-12);
}

"""The worked example: specialist means 0.2333, 0.5, -0.0333, 0.25, and 0."""
def example_votes -> dict[Specialist, list[Vote]] {
    return {
        # x = 0.4, 0.3, 0: mean 0.7 / 3
        Specialist.FUNDAMENTALS: [vote(Stance.BUY, 0.8), vote(Stance.BUY, 0.6), vote(Stance.HOLD, 0.5)],
        # x = 0.9, 0.35, 0.25: mean 0.5
        Specialist.TECHNICAL: [vote(Stance.STRONG_BUY, 0.9), vote(Stance.BUY, 0.7), vote(Stance.BUY, 0.5)],
        # x = -0.3, 0, 0.2: mean -0.1 / 3
        Specialist.NEWS: [vote(Stance.SELL, 0.6), vote(Stance.HOLD, 0.4), vote(Stance.BUY, 0.4)],
        # x = 0.25 three times
        Specialist.MACRO: [vote(Stance.BUY, 0.5), vote(Stance.BUY, 0.5), vote(Stance.BUY, 0.5)],
        Specialist.FLOW: [vote(Stance.HOLD, 0.9), vote(Stance.HOLD, 0.2), vote(Stance.HOLD, 0.5)]
    };
}

def random_votes(rng: random.Random) -> dict[Specialist, list[Vote]] {
    stances = list(Stance);
    found: dict[Specialist, list[Vote]] = {};
    for s in list(Specialist) {
        found[s] = [vote(rng.choice(stances), round(rng.random(), 2)) for _ in range(rng.randint(0, 5))];
    }
    return found;
}

def flipped(votes: dict[Specialist, list[Vote]]) -> dict[Specialist, list[Vote]] {
    opposite: dict[Stance, Stance] = {
        Stance.STRONG_SELL: Stance.STRONG_BUY,
        Stance.SELL: Stance.BUY,
        Stance.HOLD: Stance.HOLD,
        Stance.BUY: Stance.SELL,
        Stance.STRONG_BUY: Stance.STRONG_SELL
    };
    return {s: [vote(opposite[v.stance], v.confidence) for v in vs] for (s, vs) in votes.items()};
}

test "a vote's signed score is its stance halved times its confidence" {
    assert close_to(signed_score(vote(Stance.STRONG_BUY, 0.9)), 0.9);
    assert close_to(signed_score(vote(Stance.BUY, 0.6)), 0.3);
    assert signed_score(vote(Stance.HOLD, 1.0)) == 0.0;
    assert close_to(signed_score(vote(Stance.SELL, 0.5)), -0.25);
    assert close_to(signed_score(vote(Stance.STRONG_SELL, 1.0)), -1.0);
}

test "the worked example gives C = 0.19 and A = 0.6" {
    c = consensus(example_votes(), "AAPL");
    assert c is not None;
    # C = (0.7/3 + 0.5 - 0.1/3 + 0.25 + 0) / 5 = 0.95 / 5
    assert close_to(c.score, 0.19);
    # Agreeing shares: 2/3, 3/3, 1/3, 3/3, 0/3; HOLD votes never agree.
    assert close_to(c.agreement, 0.6);
    assert close_to(c.specialist_scores["technical"], 0.5);
    assert close_to(c.specialist_scores["news"], -0.1 / 3);
    assert c.weights == {"flow": 1.0, "fundamentals": 1.0, "macro": 1.0, "news": 1.0, "technical": 1.0};
    assert c.samples_used == 15;
    assert close_to(c.conviction(), 0.19 * 0.6);
    # The interval holds C and lies within the specialists' range.
    assert -0.1 / 3 <= c.ci_low <= c.score <= c.ci_high <= 0.5;
}

test "a specialist with no valid vote is left out, and no votes give no consensus" {
    votes = example_votes();
    votes[Specialist.FLOW] = [];
    c = consensus(votes, "AAPL");
    assert c is not None and "flow" not in c.specialist_scores;
    assert close_to(c.score, 0.95 / 4);
    assert consensus({s: [] for s in list(Specialist)}, "AAPL") is None;
    assert consensus({}, "AAPL") is None;
}

test "an all-HOLD panel has C = 0 and no agreement" {
    c = consensus({s: [vote(Stance.HOLD, 0.8)] * 3 for s in list(Specialist)}, "AAPL");
    assert c is not None;
    assert (c.score, c.agreement, c.ci_low, c.ci_high) == (0.0, 0.0, 0.0, 0.0);
}

test "the bootstrap resamples whole specialists, reproducibly for a seed" {
    means = [0.1, 0.5, -0.2, 0.3, 0.0];
    weights = [1.0] * 5;
    first = bootstrap_interval(means, weights, "MSFT:2026-10-16");
    assert first == bootstrap_interval(means, weights, "MSFT:2026-10-16");
    # Every draw is a mean of five of the specialists' means, so it stays inside their range.
    assert -0.2 <= first[0] < first[1] <= 0.5;
    # One specialist, or identical specialists, cannot vary.
    assert bootstrap_interval([0.4], [1.0], "x") == (0.4, 0.4);
    (low, high) = bootstrap_interval([0.2, 0.2, 0.2], [1.0] * 3, "x");
    assert close_to(low, 0.2) and close_to(high, 0.2);
}

test "the quantile interpolates between neighbors" {
    values = [0.0, 1.0, 2.0, 3.0, 4.0];
    assert quantile(values, 0.0) == 0.0;
    assert quantile(values, 1.0) == 4.0;
    assert quantile(values, 0.5) == 2.0;
    assert close_to(quantile(values, 0.05), 0.2);
    assert quantile([7.0], 0.95) == 7.0;
}

test "the decision rule follows TDD §7's table" {
    # BUY needs C, A, and an interval above zero; held, it is an ADD.
    assert decide(0.4, 0.7, 0.1, False, False, CONFIG) == TradeAction.BUY;
    assert decide(0.4, 0.7, 0.1, True, False, CONFIG) == TradeAction.ADD;
    assert decide(0.35, 0.6, 0.01, False, False, CONFIG) == TradeAction.BUY;
    assert decide(0.34, 0.7, 0.1, False, False, CONFIG) == TradeAction.NO_ACTION;
    assert decide(0.4, 0.59, 0.1, False, False, CONFIG) == TradeAction.NO_ACTION;
    assert decide(0.4, 0.7, 0.0, False, False, CONFIG) == TradeAction.NO_ACTION;
    # A held ticker exits at C <= -0.25 or when its exit fires, whatever the panel says.
    assert decide(-0.25, 0.9, -0.5, True, False, CONFIG) == TradeAction.SELL;
    assert decide(0.8, 0.9, 0.5, True, True, CONFIG) == TradeAction.SELL;
    # Held in between: HOLD, or TRIM when agreement is below 0.5.
    assert decide(0.1, 0.5, -0.1, True, False, CONFIG) == TradeAction.HOLD;
    assert decide(0.1, 0.49, -0.1, True, False, CONFIG) == TradeAction.TRIM;
    # Held with a strong C but weak agreement: unchanged.
    assert decide(0.5, 0.4, 0.2, True, False, CONFIG) == TradeAction.NO_ACTION;
    # Not held: never a sell, trim, hold, or add, and an exit cannot fire.
    assert decide(-0.9, 0.9, -1.0, False, True, CONFIG) == TradeAction.NO_ACTION;
}

test "a result near a threshold is ambiguous, and one far from every threshold is not" {
    near = Consensus(score=0.37, agreement=0.8, ci_low=0.2, ci_high=0.5);
    assert draft_action(near, False) == TradeAction.BUY and ambiguous(near, False);
    weak_agreement = Consensus(score=0.6, agreement=0.62, ci_low=0.3, ci_high=0.8);
    assert ambiguous(weak_agreement, False);
    interval_near_zero = Consensus(score=0.6, agreement=0.9, ci_low=0.03, ci_high=0.8);
    assert ambiguous(interval_near_zero, False);
    clear_buy = Consensus(score=0.6, agreement=0.9, ci_low=0.3, ci_high=0.8);
    assert not ambiguous(clear_buy, False);
    clear_nothing = Consensus(score=0.05, agreement=0.3, ci_low=-0.2, ci_high=0.25);
    assert not ambiguous(clear_nothing, False);
    near_sell = Consensus(score=-0.22, agreement=0.7, ci_low=-0.4, ci_high=0.0);
    assert ambiguous(near_sell, True);
    assert not ambiguous(near_sell, True, exit_triggered=True);
}

test "a ticker needs 60% of its samples back" {
    assert enough_samples(9, 15);
    assert not enough_samples(8, 15);
    assert not enough_samples(0, 0);
}

test "every result is in range, its interval holds C, and opposite votes mirror it" {
    rng = random.Random(449);
    for i in range(300) {
        votes = random_votes(rng);
        c = consensus(votes, f"T{i}");
        if c is None {
            assert not any(votes.values());
            continue;
        }
        assert -1.0 <= c.score <= 1.0;
        assert 0.0 <= c.agreement <= 1.0;
        assert 0.0 <= c.conviction() <= 1.0;
        assert c.ci_low <= c.ci_high;
        (lowest, highest) = (min(c.specialist_scores.values()), max(c.specialist_scores.values()));
        assert lowest - 1e-12 <= c.ci_low and c.ci_high <= highest + 1e-12;
        assert lowest - 1e-12 <= c.score <= highest + 1e-12;
        assert c.samples_used == sum(len(vs) for vs in votes.values());
        mirror = consensus(flipped(votes), f"T{i}");
        assert mirror is not None;
        assert close_to(mirror.score, -c.score);
        assert close_to(mirror.agreement, c.agreement);
        assert close_to(mirror.ci_low, -c.ci_high) and close_to(mirror.ci_high, -c.ci_low);
    }
}

test "the decision rule never trades against its own conditions" {
    rng = random.Random(2026);
    for _ in range(2000) {
        (score, agreement) = (rng.uniform(-1, 1), rng.random());
        low = rng.uniform(-1, 1);
        (held, fired) = (rng.random() < 0.5, rng.random() < 0.2);
        action = decide(score, agreement, low, held, fired, CONFIG);
        if action in (TradeAction.BUY, TradeAction.ADD) {
            assert score >= 0.35 and agreement >= 0.6 and low > 0 and not (held and fired);
        }
        if not held {
            assert action in (TradeAction.BUY, TradeAction.NO_ACTION);
        } else {
            assert action != TradeAction.BUY;
        }
        if action == TradeAction.SELL {
            assert fired or score <= -0.25;
        }
    }
}
