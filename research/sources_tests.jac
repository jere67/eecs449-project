"""Invariants of the versioned source config (TDD §6, collector rules)."""
import re;
import from research.sources { DATASETS, SOURCES, SOURCES_VERSION, Source }

test "every dataset belongs to a configured source" {
    unknown = [d.name for d in DATASETS.values() if d.source not in SOURCES];
    assert not unknown, unknown;
    assert all(d.name.split(".")[0] in d.source for d in DATASETS.values());
}

test "limits, budgets, cache lifetimes, and freshness limits are positive" {
    for s in SOURCES.values() {
        assert s.per_minute > 0 and s.burst >= 1 and s.run_budget > 0, s.name;
    }
    for d in DATASETS.values() {
        assert d.max_age_hours > 0, d.name;
        assert d.cache_ttl_hours is None or d.cache_ttl_hours > 0, d.name;
    }
}

test "each source has its own https base URL and override variable" {
    for s in SOURCES.values() {
        assert s.base_url.startswith("https://"), s.name;
        assert re.fullmatch(r"[A-Z][A-Z0-9_]*_URL", s.base_url_env), s.base_url_env;
    }
    envs = [s.base_url_env for s in SOURCES.values()];
    assert len(set(envs)) == len(envs);
}

test "sources on one provider limit pace to the same rate" {
    groups: dict[str, set[tuple[float, int]]] = {};
    for s in SOURCES.values() {
        groups.setdefault(s.limit_group, set()).add((s.per_minute, s.burst));
    }
    assert all(len(rates) == 1 for rates in groups.values()), groups;
}

test "a run budget over half a daily limit is refused" {
    with testraises(ValueError, `match="over half the daily limit") {
        Source(
            name="capped",
            base_url="https://example.com",
            base_url_env="CAPPED_URL",
            per_minute=5,
            burst=1,
            run_budget=13,
            daily_limit=25
        );
    }
    assert Source(
        name="capped",
        base_url="https://example.com",
        base_url_env="CAPPED_URL",
        per_minute=5,
        burst=1,
        run_budget=12,
        daily_limit=25
    ).limit_group == "capped";
}

test "the config is versioned" {
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}\.\d+", SOURCES_VERSION);
}
