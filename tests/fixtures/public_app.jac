"""A minimal app that writes team-graph nodes the way the scheduled job will, for public_tests.jac."""
import from models.agents { Domain, Evidence, ResearchReport, Stance }
import from models.graph {
    Coverage,
    CoverageReason,
    Covers,
    Portfolio,
    PortfolioMode,
    Ran,
    Researched,
    ResearchRecord,
    Run
}
import from run.public { public }

"""Write a public run with one public coverage, plus a coverage left private."""
def:priv seed_team_graph -> str {
    team = public(
        root.shared ++> Portfolio(
            name="team", mode=PortfolioMode.AUTO, starting_cash=100000.0, opened_at="2026-10-06T13:30:00+00:00"
        )
    );
    run = public(team +>:Ran():+> Run(run_date="2026-10-06", started_at="2026-10-06T11:30:00+00:00"));
    aapl = public(
        run +>:Covers():+> Coverage(ticker="AAPL", sector="Information Technology", reason=CoverageReason.SCREEN)
    );
    public(
        aapl +>:Researched():+> ResearchRecord(
            ticker="AAPL",
            domain=Domain.FUNDAMENTALS,
            as_of="2026-10-06T11:40:00+00:00",
            model="mockllm",
            body=ResearchReport(
                summary="Revenue grew.",
                view=Stance.BUY,
                confidence=0.6,
                evidence=[Evidence(claim="Revenue grew 12%.", source_url="https://www.sec.gov/x", published="2026-10-01")]
            )
        )
    );
    run +>:Covers():+> Coverage(ticker="PRIVATE", sector="Energy", reason=CoverageReason.SCREEN);
    return "ok";
}

"""Every node a caller can reach from root.shared, as type:key labels."""
def:pub read_team_graph -> list[str] {
    seen: list[str] = [];
    for team in [root.shared -->[?:Portfolio]] {
        seen.append(f"portfolio:{team.name}");
        for run in [team ->:Ran:->] {
            seen.append(f"run:{run.run_date}");
            for cov in [run ->:Covers:->] {
                seen.append(f"coverage:{cov.ticker}");
            }
        }
    }
    return seen;
}

"""Every research record a caller can reach, as stored nodes, the way the dashboard reads them."""
def:pub read_research -> list[ResearchRecord] {
    return [root.shared -->[?:Portfolio] ->:Ran:-> ->:Covers:-> ->:Researched:->];
}
