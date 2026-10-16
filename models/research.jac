"""Provenance for collected data (TDD §6, collector rules).

Every datum a collector returns carries a Stamp before it reaches an agent, so a research
report can cite where each claim came from and when, and stale data can be dropped.
Timestamps are ISO 8601 strings in UTC, as in models/graph.jac.
"""

obj Stamp {
    has source: str,
        dataset: str,
        source_url: str,
        published_at: str,
        fetched_at: str;
}

"""Base for every collector output type: one datum and its provenance."""
obj Stamped {
    has stamp: Stamp;
}

"""The market-regime figures the risk gate reads (TDD §8, regime filter), computed in code
from SPY's daily bars rather than taken from the Macro sub-agent. `spy_vol_20` is SPY's
20-day realized volatility, annualized, as a fraction. A missing figure is None, and the
gate treats it as unknown."""
obj RegimeInputs {
    has spy_close: float | None = None,
        spy_sma_200: float | None = None,
        spy_vol_20: float | None = None,
        spy_as_of: str = "";

    def spy_above_200d -> bool | None {
        if self.spy_close is None or self.spy_sma_200 is None {
            return None;
        }
        return self.spy_close > self.spy_sma_200;
    }
}
