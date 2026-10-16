"""The Arbiter (TDD §7, Arbiter): one `by arbiter_llm(temperature=0.2)` call per ticker that
reviews the consensus engine's draft action and writes the decision's thesis, its two biggest
risks, and an exit condition.

Its authority is one-sided, and code enforces it: a BUY may become NO ACTION and an ADD may
become HOLD, and nothing else changes, so one model can never talk the ensemble into a trade
or into more risk. The time stop is a trading date the caller computes from the votes'
horizons (TDD §3, rule 11), never one the model works out.

The call site follows TDD §4: a parse that still fails after `max_output_retries` is tried
once more through `retry_llm`, and any other error, or a second failure, gives a safe ruling
that downgrades a buy or an add and keeps any other draft, with the reason stored.
"""
import time;
import from jaclang.byllm.lib { OutputConversionError }
import from agents.models { arbiter_llm, retry_llm }
import from analysis.consensus { Consensus, signed_score }
import from models.agents { Domain, MacroReport, ResearchReport, Specialist, Vote }
import from models.graph { TradeAction }

# The only changes the Arbiter may make (TDD §7, Arbiter).
glob DOWNGRADES: dict[TradeAction, TradeAction] = {TradeAction.BUY: TradeAction.NO_ACTION, TradeAction.ADD: TradeAction.HOLD};

glob ACTION_MEANING: dict[TradeAction, str] = {
    TradeAction.BUY: "BUY: open a new position",
    TradeAction.ADD: "ADD: buy more of a held position",
    TradeAction.HOLD: "HOLD: keep the held position as it is",
    TradeAction.TRIM: "TRIM: sell part of the held position",
    TradeAction.SELL: "SELL: exit the held position",
    TradeAction.NO_ACTION: "NO ACTION: do not trade"
};

glob MAX_RATIONALES: int = 3;
glob MAX_SUMMARY_CHARS: int = 900;
glob MAX_ITEM_CHARS: int = 300;

enum Verdict: str {
    CONFIRM = "CONFIRM",
    DOWNGRADE = "DOWNGRADE"
}

obj Review {
    has verdict: Verdict,
        reason: str,
        thesis: str,
        risks: list[str],
        exit_condition: str;

    def postinit {
        if len([r for r in self.risks if r.strip()]) < 2 {
            raise ValueError("risks must name the two biggest risks");
        }
        if not self.exit_condition.strip() {
            raise ValueError("exit_condition must not be empty");
        }
    }
}

sem Review.verdict = "CONFIRM the draft action, or DOWNGRADE it when the evidence does not support it.";
sem Review.reason = "One or two sentences on why you confirmed or downgraded.";
sem Review.thesis = "Two to four sentences: why this action is right for this stock now.";
sem Review.risks = "The two biggest risks to the thesis, most serious first.";
sem Review.exit_condition = "A price level or an event that would end the position, such as a close below a stated support or a guidance cut.";

"""You are the Arbiter of an investment committee. The committee's specialists voted
independently, and code turned their votes into the draft action. Review it against the
consensus statistics, the strongest arguments on each side, and the research.

Rules:
- CONFIRM the draft, or DOWNGRADE it when the evidence is weak, stale, or contradicted. You
  can never make an action stronger.
- Write the thesis, the two biggest risks, and an exit condition for the action that
  results; an exit condition names a price level or an event, never a date.
- The time stop is already set; never work out dates yourself.
- Use only the material given."""
def review_case(ticker: str, as_of: str, draft: str, statistics: str, arguments: str, research: str, time_stop: str) -> Review by arbiter_llm(temperature=0.2, max_output_retries=1);

"""You are the Arbiter of an investment committee. The committee's specialists voted
independently, and code turned their votes into the draft action. Review it against the
consensus statistics, the strongest arguments on each side, and the research.

Rules:
- CONFIRM the draft, or DOWNGRADE it when the evidence is weak, stale, or contradicted. You
  can never make an action stronger.
- Write the thesis, the two biggest risks, and an exit condition for the action that
  results; an exit condition names a price level or an event, never a date.
- The time stop is already set; never work out dates yourself.
- Use only the material given."""
def review_case_retry(ticker: str, as_of: str, draft: str, statistics: str, arguments: str, research: str, time_stop: str) -> Review by retry_llm(temperature=0.2, max_output_retries=1);

sem review_case.draft = "The draft action and what it means.";
sem review_case.statistics = "The consensus score C in [-1, 1], the agreement A in [0, 1], C's 90% interval, and each specialist's mean score.";
sem review_case.arguments = "The specialists' strongest rationales for and against, with their stance and confidence.";
sem review_case.research = "Summaries and risks of the research reports on this stock and the market.";
sem review_case.time_stop = "The trading date by which the position is reviewed if no exit fires.";
sem review_case_retry.draft = "The draft action and what it means.";
sem review_case_retry.statistics = "The consensus score C in [-1, 1], the agreement A in [0, 1], C's 90% interval, and each specialist's mean score.";
sem review_case_retry.arguments = "The specialists' strongest rationales for and against, with their stance and confidence.";
sem review_case_retry.research = "Summaries and risks of the research reports on this stock and the market.";
sem review_case_retry.time_stop = "The trading date by which the position is reviewed if no exit fires.";

"""Everything the Arbiter reads about one ticker. `votes` are the panel's valid votes."""
obj Docket {
    has ticker: str,
        as_of: str,
        draft: TradeAction,
        consensus: Consensus,
        votes: dict[Specialist, list[Vote]],
        reports: dict[Domain, ResearchReport],
        time_stop: str;
    has macro: MacroReport | None = None;
}

"""The Arbiter's ruling: the final action and the decision's text. `verdict` records what the
Arbiter said, and `error` why it could not say it."""
obj Ruling {
    has action: TradeAction,
        thesis: str,
        risks: list[str],
        exit_condition: str;
    has verdict: str = "",
        downgrade_reason: str = "",
        model: str = "",
        error: str = "",
        retried: bool = False,
        seconds: float = 0.0;
}

"""Rule on `docket`. Never raises: a failure gives `safe_ruling`."""
def arbitrate(docket: Docket) -> Ruling {
    started = time.monotonic();
    (draft, stats, arguments, research) = (ACTION_MEANING[docket.draft], statistics_text(docket.consensus), arguments_text(docket.votes), research_text(docket.reports, docket.macro));
    retried = False;
    try {
        try {
            said = review_case(docket.ticker, docket.as_of, draft, stats, arguments, research, docket.time_stop);
            model = arbiter_llm.model_name;
        } except OutputConversionError {
            retried = True;
            said = review_case_retry(docket.ticker, docket.as_of, draft, stats, arguments, research, docket.time_stop);
            model = retry_llm.model_name;
        }
    } except Exception as e {
        ruling = safe_ruling(docket, f"{type(e).__name__}: {str(e)[:300]}");
        ruling.retried = retried;
        ruling.seconds = time.monotonic() - started;
        return ruling;
    }
    (action, verdict, reason) = apply(docket.draft, said);
    return Ruling(
        action=action,
        thesis=said.thesis.strip(),
        risks=[r.strip() for r in said.risks if r.strip()][:2],
        exit_condition=said.exit_condition.strip(),
        verdict=verdict,
        downgrade_reason=reason,
        model=model,
        retried=retried,
        seconds=time.monotonic() - started
    );
}

"""The action after the Arbiter's verdict, the verdict as recorded, and the downgrade reason.
A downgrade applies only to a BUY or an ADD; asked of any other draft, the draft stands and
the verdict is recorded as not applied."""
def apply(draft: TradeAction, said: Review) -> tuple[TradeAction, str, str] {
    if said.verdict == Verdict.CONFIRM {
        return (draft, Verdict.CONFIRM.value, "");
    }
    if draft in DOWNGRADES {
        return (DOWNGRADES[draft], Verdict.DOWNGRADE.value, said.reason.strip());
    }
    return (draft, f"{Verdict.DOWNGRADE.value} (not applied to {draft.value})", "");
}

"""The ruling when the Arbiter cannot rule: a buy becomes NO ACTION and an add becomes HOLD,
since no reviewed trade beats an unreviewed one, and any other draft stands, since it adds
no risk."""
def safe_ruling(docket: Docket, error: str) -> Ruling {
    action = DOWNGRADES.get(docket.draft, docket.draft);
    c = docket.consensus;
    return Ruling(
        action=action,
        thesis=f"The Arbiter could not review this ticker, so the draft {docket.draft.value} became {action.value}. The panel's consensus was C = {c.score:+.2f} with agreement {c.agreement:.0%}.",
        risks=["The decision was not reviewed by the Arbiter.", "The consensus may rest on weak or stale evidence."],
        exit_condition=f"Review at the time stop on {docket.time_stop}, or sooner if the consensus turns negative.",
        verdict="unavailable",
        downgrade_reason=f"Arbiter unavailable: {error}" if action != docket.draft else "",
        error=error
    );
}

def statistics_text(c: Consensus) -> str {
    lines = [
        f"C = {c.score:+.3f}; A = {c.agreement:.2f}; 90% interval for C: [{c.ci_low:+.3f}, {c.ci_high:+.3f}]; valid samples: {c.samples_used}.",
        "Specialist means: " + ", ".join(f"{name} {score:+.2f}" for (name, score) in c.specialist_scores.items()) + "."
    ];
    return "\n".join(lines);
}

"""The strongest rationales on each side, by signed score."""
def arguments_text(votes: dict[Specialist, list[Vote]]) -> str {
    scored = sorted(
        [(signed_score(v), s, v) for (s, vs) in votes.items() for v in vs],
        key=lambda (t: tuple[float, Specialist, Vote]) { t[0]; }
    );
    def line(t: tuple[float, Specialist, Vote]) -> str {
        return f"- {t[1].value} ({t[2].stance.value}, confidence {t[2].confidence:.2f}): {_clip(t[2].rationale, MAX_ITEM_CHARS)}";
    }
    bulls = [line(t) for t in reversed(scored) if t[0] > 0][:MAX_RATIONALES];
    bears = [line(t) for t in scored if t[0] < 0][:MAX_RATIONALES];
    return "\n".join(["For:"] + (bulls or ["- none"]) + ["Against:"] + (bears or ["- none"]));
}

def research_text(reports: dict[Domain, ResearchReport], macro: MacroReport | None) -> str {
    sections: list[str] = [];
    for domain in [Domain.MARKET, Domain.FUNDAMENTALS, Domain.NEWS] {
        if domain in reports {
            r = reports[domain];
            sections.append(_section(f"{domain.value} research", r.summary, r.risks, r.data_gaps));
        }
    }
    if macro is not None {
        sections.append(_section("macro research (the whole market)", macro.summary, macro.risks, macro.data_gaps));
    }
    return "\n\n".join(sections) or "No research reports.";
}

def _section(label: str, summary: str, risks: list[str], gaps: list[str]) -> str {
    lines = [f"## {label}", _clip(summary, MAX_SUMMARY_CHARS)];
    if risks {
        lines.append("Risks: " + "; ".join(_clip(r, MAX_ITEM_CHARS) for r in risks[:4]));
    }
    if gaps {
        lines.append("Data gaps: " + "; ".join(_clip(g, MAX_ITEM_CHARS) for g in gaps[:4]));
    }
    return "\n".join(lines);
}

def _clip(text: str, limit: int) -> str {
    text = " ".join(text.split());
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…";
}
