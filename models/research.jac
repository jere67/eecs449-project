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
