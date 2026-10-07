"""Typed agent inputs and outputs (TDD §3, §7).

Agents fill these objs through byLLM, which validates them against the declared types.
Identity fields an agent cannot know better than the code (ticker, domain, dates) live on
the storage nodes in models/graph.jac, so no agent is asked to repeat them.
Every enum a model returns is a `: str` enum: a plain enum becomes an integer schema and
rejects "BUY" (TDD §3, rule 4).
"""

enum Stance: str {
    STRONG_SELL = "STRONG_SELL",
    SELL = "SELL",
    HOLD = "HOLD",
    BUY = "BUY",
    STRONG_BUY = "STRONG_BUY"
}

glob STANCE_SCORE: dict[Stance, int] = {
    Stance.STRONG_SELL: -2,
    Stance.SELL: -1,
    Stance.HOLD: 0,
    Stance.BUY: 1,
    Stance.STRONG_BUY: 2
};

enum RiskRegime: str {
    RISK_OFF = "RISK_OFF",
    NEUTRAL = "NEUTRAL",
    RISK_ON = "RISK_ON"
}

"""Research domains: one sub-agent each (TDD §6)."""
enum Domain: str {
    MARKET = "market",
    FUNDAMENTALS = "fundamentals",
    NEWS = "news",
    MACRO = "macro"
}

"""Specialist roles on the analysis panel (TDD §7)."""
enum Specialist: str {
    FUNDAMENTALS = "fundamentals",
    TECHNICAL = "technical",
    NEWS = "news",
    MACRO = "macro",
    FLOW = "flow"
}

"""Raise when a model returns a value outside [0, 1]; byLLM retries the parse with this message."""
def check_unit_interval(name: str, value: float) {
    if value < 0.0 or value > 1.0 {
        raise ValueError(f"{name} must be in [0, 1], got {value}");
    }
}

obj Evidence {
    has claim: str,
        source_url: str,
        published: str;

    def postinit {
        if not self.source_url.startswith(("https://", "http://")) {
            raise ValueError(f"source_url must be an http(s) URL, got {self.source_url!r}");
        }
    }
}

sem Evidence.claim = "One factual statement taken from the provided data, in your own words.";
sem Evidence.source_url = "The URL of the source this claim came from, copied exactly from the input.";
sem Evidence.published = "When the source was published, copied exactly from the input.";

obj ResearchReport {
    has summary: str,
        view: Stance,
        confidence: float;
    has evidence: list[Evidence] = [],
        risks: list[str] = [],
        data_gaps: list[str] = [];

    def postinit {
        check_unit_interval("confidence", self.confidence);
    }
}

sem ResearchReport.summary = "Three to five sentences on what the data says about this stock in your domain.";
sem ResearchReport.view = "Your overall read of the stock from this domain alone.";
sem ResearchReport.confidence = "Probability in [0, 1] that the view is right.";
sem ResearchReport.evidence = "Every factual claim the summary relies on, each with its source.";
sem ResearchReport.risks = "The main ways the view could be wrong.";
sem ResearchReport.data_gaps = "Inputs that were missing, stale, or contradictory.";

obj MacroReport {
    has summary: str,
        regime: RiskRegime,
        confidence: float;
    has evidence: list[Evidence] = [],
        risks: list[str] = [],
        data_gaps: list[str] = [];

    def postinit {
        check_unit_interval("confidence", self.confidence);
    }
}

sem MacroReport.summary = "Three to five sentences on rates, inflation, growth, volatility, and sector rotation.";
sem MacroReport.regime = "Whether conditions favor taking equity risk, avoiding it, or neither.";
sem MacroReport.confidence = "Probability in [0, 1] that the regime call is right.";
sem MacroReport.evidence = "Every factual claim the summary relies on, each with its source.";
sem MacroReport.risks = "Scheduled releases or developments that could change the regime.";
sem MacroReport.data_gaps = "Series that were missing, stale, or contradictory.";

obj Vote {
    has stance: Stance,
        confidence: float,
        horizon_days: int,
        rationale: str;
    has cited_evidence: list[int] = [];

    def postinit {
        check_unit_interval("confidence", self.confidence);
        if self.horizon_days < 1 {
            raise ValueError(f"horizon_days must be at least 1, got {self.horizon_days}");
        }
    }
}

sem Vote.stance = "Your call on the stock over horizon_days.";
sem Vote.confidence = "Probability in [0, 1] that the stance is right over horizon_days.";
sem Vote.horizon_days = "How many trading days the call is meant to hold.";
sem Vote.rationale = "Two to four sentences explaining the call from your specialty alone.";
sem Vote.cited_evidence = "Indices of the evidence items this vote relies on; never empty.";
