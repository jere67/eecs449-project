"""The team graph's typed edges connect the decision trail end to end (TDD §11)."""
import uuid;
import from models.agents { Domain, Evidence, ResearchReport, Specialist, Stance, Vote }
import from models.graph {
    CheckedBy,
    Coverage,
    CoverageReason,
    Covers,
    Decided,
    Decision,
    Fill,
    FilledBy,
    Order,
    OrderPurpose,
    OrderSide,
    Placed,
    Portfolio,
    PortfolioMode,
    Ran,
    Researched,
    ResearchRecord,
    RiskCheck,
    RiskOutcome,
    RuleResult,
    Run,
    TradeAction,
    Voted,
    VoteRecord
}

glob AT: str = "2026-10-06T13:45:00+00:00";

test "a fill traces back through order, risk check, decision, coverage, and run" {
    team = root ++> Portfolio(
        name=f"test-{uuid.uuid4()}", mode=PortfolioMode.AUTO, starting_cash=100000.0, opened_at=AT
    );
    run = team +>:Ran():+> Run(run_date="2026-10-06", started_at=AT);
    cov = run +>:Covers():+> Coverage(ticker="AAPL", sector="Information Technology", reason=CoverageReason.SCREEN);
    cov +>:Researched():+> ResearchRecord(
        ticker="AAPL",
        domain=Domain.NEWS,
        as_of=AT,
        model="mockllm",
        body=ResearchReport(
            summary="s",
            view=Stance.BUY,
            confidence=0.6,
            evidence=[Evidence(claim="c", source_url="https://example.com", published=AT)]
        )
    );
    for sample in range(3) {
        cov +>:Voted():+> VoteRecord(
            ticker="AAPL",
            specialist=Specialist.TECHNICAL,
            sample=sample,
            model="mockllm",
            body=Vote(stance=Stance.BUY, confidence=0.7, horizon_days=10, rationale="r", cited_evidence=[0])
        );
    }
    decision = cov +>:Decided():+> Decision(ticker="AAPL", action=TradeAction.BUY, conviction=0.4);
    check = decision +>:CheckedBy():+> RiskCheck(
        outcome=RiskOutcome.RESIZED,
        approved_qty=10,
        checked_at=AT,
        rules=[RuleResult(rule="per_position_cap", passed=False, qty_before=12, qty_after=10)]
    );
    order = check +>:Placed():+> Order(
        client_order_id="2026-10-06-AAPL-BUY",
        purpose=OrderPurpose.ENTRY,
        side=OrderSide.BUY,
        qty=10,
        order_type="limit",
        time_in_force="day",
        submitted_at=AT
    );
    order +>:FilledBy():+> Fill(qty=10, price=231.5, filled_at=AT);

    try {
        trail = [team ->:Ran:-> ->:Covers:-> ->:Decided:-> ->:CheckedBy:-> ->:Placed:-> ->:FilledBy:->];
        assert len(trail) == 1;
        assert trail[0].price == 231.5;
        # The checker cannot type field predicates in 0.37.12, even in the documented form.
        votes = [cov ->:Voted:->[?:VoteRecord, specialist == Specialist.TECHNICAL]];  # jac:ignore[W1051]
        assert [v.sample for v in votes] == [0, 1, 2];
        assert all(v.body.stance == Stance.BUY for v in votes);
        assert [r.body.view for r in [cov ->:Researched:->]] == [Stance.BUY];
        assert [c.rules[0].qty_after for c in [decision ->:CheckedBy:->]] == [10];
    } finally {
        for gone in [team ->:Ran:-> ->:Covers:-> ->:Researched:->] + [cov ->:Voted:->] {
            del gone;
        }
        for gone in [order ->:FilledBy:->] {
            del gone;
        }
        del order;
        del check;
        del decision;
        del cov;
        del run;
        del team;
    }
}
