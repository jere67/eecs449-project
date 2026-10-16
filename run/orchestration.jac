"""The morning run with the Orchestrator at the wheel (TDD §4): the Run Guard's `daily_run`
with the Orchestrator as its driver, on the team portfolio.

The Orchestrator's tools are the run session's own methods, so every limit it meets is the
one the fallback meets. Its loop stops with a summary when the run's request budget is down
to the reserve for that summary, or the run's deadline has passed; the Run Guard then
finishes whatever is left in fixed order and marks the run fallback.
"""
import from jaclang.byllm.types { IterationAction, IterationContext }
import from agents.orchestrator { Committee }
import from run.guard { RunOutcome, RunSession, daily_run, team_portfolio, trading_date_now }

# Requests the loop keeps back for its own closing summary.
glob SUMMARY_RESERVE: int = 2;

"""Drive `s` with the Orchestrator and return its closing summary."""
def orchestrate(s: RunSession) -> str {
    def stop_when_spent(ctx: IterationContext) -> IterationAction {
        if s.requests_left() <= SUMMARY_RESERVE or s.overdue() {
            s.actions.append(f"orchestrator stopped at iteration {ctx.iteration}: {'deadline passed' if s.overdue() else 'request budget spent'}");
            return IterationAction.ABORT_WITH_SUMMARY;
        }
        return IterationAction.CONTINUE;
    }
    committee = Committee(
        tools=[s.get_run_context, s.dispatch_research, s.request_followup, s.flag_ticker, s.convene_panel, s.submit_decisions, s.write_run_summary],
        on_iteration=stop_when_spent,
        max_iterations=s.limits.react_iterations
    );
    return committee.run(s.run_day, ", ".join(s.tickers()));
}

"""The team's morning run for `run_day` (today in New York by default)."""
def morning_run(run_day: str = "") -> RunOutcome {
    return daily_run(team_portfolio(), run_day or trading_date_now(), orchestrate);
}

"""The daily pipeline as a walker (TDD §3, code sketch). It is not an endpoint: main.jac does
not import it, and only the scheduled job starts a run (TDD §14, unauthorized run triggers)."""
walker DailyRun {
    has run_day: str = "";

    can start with Root entry {
        outcome = morning_run(self.run_day);
        report {"run_day": outcome.run_day, "status": outcome.status.value, "note": outcome.note};
    }
}
