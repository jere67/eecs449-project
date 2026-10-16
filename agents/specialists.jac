"""The specialist panel (TDD §7): Fundamentals, Technical, News and Events, Macro and Sector,
and Flow and Positioning, each a `by specialist_llm(temperature=0.8)` call that returns a
typed Vote on one ticker.

A specialist reads a Packet built in code from its primary research reports: each report's
summary, risks, and gaps, and the reports' evidence as one numbered list. It never sees
another specialist's votes, nor the research sub-agents' own views and confidences, so the
panel's errors stay independent. Every sample shows the evidence in a different seeded order
to reduce position bias; code maps the numbers a vote cites back to the packet's own order,
and a vote that cites nothing in range is discarded (FR-06).

Every call site follows TDD §4: a parse that still fails after `max_output_retries` is tried
once more through `retry_llm` at temperature 0.2, and any other error, or a second failure,
drops the sample with the error recorded. The consensus engine counts dropped samples against
the 60% minimum.
"""
import random;
import time;
import zlib;
import from jaclang.byllm.lib { OutputConversionError }
import from agents.models { retry_llm, specialist_llm }
import from models.agents { Domain, Evidence, MacroReport, ResearchReport, Specialist, Vote }

# What each specialist judges, passed to the shared prompt.
glob SPECIALIST_FOCUS: dict[Specialist, str] = {
    Specialist.FUNDAMENTALS: "Fundamentals: valuation, growth, margins, cash flow, balance sheet, guidance, and earnings quality. Judge the business and what its price already assumes, not the chart or the headlines.",
    Specialist.TECHNICAL: "Technicals: trend, momentum, support and resistance, volatility, and relative strength against the market and the sector. Judge whether price action supports owning the stock now.",
    Specialist.NEWS: "News and events: how material the recent news is, whether it is already priced in, and the catalysts ahead, such as an earnings release. Judge which way the news flow points.",
    Specialist.MACRO: "Macro and sector: the market's trend and volatility regime, rates and inflation expectations, sector rotation, and how this stock's sector sits in that regime. Judge whether conditions favor this stock.",
    Specialist.FLOW: "Flow and positioning: insider buying and selling, its size, and who traded, and analyst positioning where the reports carry it. Judge what informed money is doing; with no insider activity, say so and lean HOLD."
};

# The research reports each specialist reads (TDD §7, specialists).
glob SPECIALIST_DOMAINS: dict[Specialist, list[Domain]] = {
    Specialist.FUNDAMENTALS: [Domain.FUNDAMENTALS],
    Specialist.TECHNICAL: [Domain.MARKET],
    Specialist.NEWS: [Domain.NEWS],
    Specialist.MACRO: [Domain.MACRO, Domain.MARKET],
    Specialist.FLOW: [Domain.FUNDAMENTALS]
};

# Prompt caps (TDD §3, rule 12): the reports' own caps keep a packet near 3,000 tokens.
glob MAX_EVIDENCE_PER_REPORT: int = 25;
glob MAX_CLAIM_CHARS: int = 400;
glob MAX_SUMMARY_CHARS: int = 1200;
glob MAX_LIST_ITEMS: int = 6;

"""You are a specialist analyst on an investment committee. Vote on `ticker` from your
specialty alone, described in `focus`, using the research context and the numbered evidence.

Rules:
- cited_evidence lists the numbers, in brackets below, of the evidence items your call
  relies on; cite at least one, and only items that bear on your specialty.
- Judge only your specialty; other committee members cover the rest.
- horizon_days counts trading days; never work out calendar dates.
- With weak, stale, or mixed evidence, prefer HOLD and a lower confidence."""
def cast_vote(ticker: str, focus: str, as_of: str, research: str, evidence: str) -> Vote by specialist_llm(temperature=0.8, max_output_retries=1);

"""You are a specialist analyst on an investment committee. Vote on `ticker` from your
specialty alone, described in `focus`, using the research context and the numbered evidence.

Rules:
- cited_evidence lists the numbers, in brackets below, of the evidence items your call
  relies on; cite at least one, and only items that bear on your specialty.
- Judge only your specialty; other committee members cover the rest.
- horizon_days counts trading days; never work out calendar dates.
- With weak, stale, or mixed evidence, prefer HOLD and a lower confidence."""
def cast_vote_retry(ticker: str, focus: str, as_of: str, research: str, evidence: str) -> Vote by retry_llm(temperature=0.2, max_output_retries=1);

sem cast_vote.focus = "Your specialty and what it judges.";
sem cast_vote.as_of = "The run date, as YYYY-MM-DD; the research is as of this date.";
sem cast_vote.research = "Summaries, risks, and data gaps of the research reports you read.";
sem cast_vote.evidence = "Numbered evidence items, each a claim with its source and publish time.";
sem cast_vote_retry.focus = "Your specialty and what it judges.";
sem cast_vote_retry.as_of = "The run date, as YYYY-MM-DD; the research is as of this date.";
sem cast_vote_retry.research = "Summaries, risks, and data gaps of the research reports you read.";
sem cast_vote_retry.evidence = "Numbered evidence items, each a claim with its source and publish time.";

"""One research report as a specialist reads it: no view or confidence, only what it found."""
obj ReportView {
    has label: str,
        summary: str;
    has risks: list[str] = [],
        data_gaps: list[str] = [],
        evidence: list[Evidence] = [];
}

def report_view(domain: Domain, r: ResearchReport) -> ReportView {
    return ReportView(label=f"{domain.value} research", summary=r.summary, risks=r.risks, data_gaps=r.data_gaps, evidence=r.evidence);
}

def macro_view(m: MacroReport) -> ReportView {
    return ReportView(label="macro research (the whole market, not this stock)", summary=m.summary, risks=m.risks, data_gaps=m.data_gaps, evidence=m.evidence);
}

"""What one specialist reads about one ticker. `evidence` is in the packet's own order, which
the indices stored on a Vote refer to (0-based); samples show it shuffled."""
obj Packet {
    has specialist: Specialist,
        ticker: str,
        as_of: str,
        research: str,
        evidence: list[Evidence];

    """The order sample `sample` shows the evidence in, as packet indices, fixed by the run
    date, ticker, specialist, and sample number."""
    def order(sample: int) -> list[int] {
        shown = list(range(len(self.evidence)));
        random.Random(zlib.crc32(f"{self.as_of}:{self.ticker}:{self.specialist.value}:{sample}".encode())).shuffle(shown);
        return shown;
    }

    def render_evidence(shown: list[int]) -> str {
        return "\n".join(f"[{n}] {_clip(self.evidence[i].claim, MAX_CLAIM_CHARS)} (source: {self.evidence[i].source_url}; published {self.evidence[i].published})" for (n, i) in enumerate(shown, start=1));
    }
}

"""The packet for `specialist` on `ticker`, from the ticker's reports by domain and the run's
macro report. A missing report is named in the research text and adds no evidence."""
def packet(specialist: Specialist, ticker: str, as_of: str, reports: dict[Domain, ResearchReport], macro: MacroReport | None) -> Packet {
    views: list[ReportView] = [];
    missing: list[str] = [];
    for domain in SPECIALIST_DOMAINS[specialist] {
        if domain == Domain.MACRO {
            if macro is not None {
                views.append(macro_view(macro));
            } else {
                missing.append("macro");
            }
        } elif domain in reports {
            views.append(report_view(domain, reports[domain]));
        } else {
            missing.append(domain.value);
        }
    }
    sections = [_section(v) for v in views];
    if missing {
        sections.append(f"Missing research: {', '.join(missing)}.");
    }
    evidence = [e for v in views for e in v.evidence[:MAX_EVIDENCE_PER_REPORT]];
    return Packet(specialist=specialist, ticker=ticker, as_of=as_of, research="\n\n".join(sections), evidence=evidence);
}

def _section(v: ReportView) -> str {
    lines = [f"## {v.label}", _clip(v.summary, MAX_SUMMARY_CHARS)];
    if v.risks {
        lines.append("Risks: " + "; ".join(_clip(r, MAX_CLAIM_CHARS) for r in v.risks[:MAX_LIST_ITEMS]));
    }
    if v.data_gaps {
        lines.append("Data gaps: " + "; ".join(_clip(g, MAX_CLAIM_CHARS) for g in v.data_gaps[:MAX_LIST_ITEMS]));
    }
    return "\n".join(lines);
}

"""One sample's vote and how it was produced. `vote` is None when the sample was dropped, with
why in `error`."""
obj VoteResult {
    has specialist: Specialist,
        sample: int;
    has vote: Vote | None = None,
        model: str = "",
        error: str = "",
        retried: bool = False,
        seconds: float = 0.0;

    def valid -> bool {
        return self.vote is not None;
    }
}

"""Draw sample `sample` from the packet's specialist. Never raises: a failure drops the
sample with the error recorded, so one bad response never stops the panel."""
def sample_vote(p: Packet, sample: int) -> VoteResult {
    started = time.monotonic();
    if not p.evidence {
        return VoteResult(specialist=p.specialist, sample=sample, error="no evidence to judge", seconds=time.monotonic() - started);
    }
    shown = p.order(sample);
    (focus, evidence) = (SPECIALIST_FOCUS[p.specialist], p.render_evidence(shown));
    retried = False;
    try {
        try {
            cast = cast_vote(p.ticker, focus, p.as_of, p.research, evidence);
            model = specialist_llm.model_name;
        } except OutputConversionError {
            retried = True;
            cast = cast_vote_retry(p.ticker, focus, p.as_of, p.research, evidence);
            model = retry_llm.model_name;
        }
    } except Exception as e {
        return VoteResult(specialist=p.specialist, sample=sample, error=f"{type(e).__name__}: {str(e)[:300]}", retried=retried, seconds=time.monotonic() - started);
    }
    cited = sorted({shown[n - 1] for n in cast.cited_evidence if 1 <= n <= len(shown)});
    if not cited {
        return VoteResult(specialist=p.specialist, sample=sample, model=model, error=f"cited no evidence item in range: {cast.cited_evidence}", retried=retried, seconds=time.monotonic() - started);
    }
    checked = Vote(stance=cast.stance, confidence=cast.confidence, horizon_days=cast.horizon_days, rationale=cast.rationale, cited_evidence=cited);
    return VoteResult(specialist=p.specialist, sample=sample, vote=checked, model=model, retried=retried, seconds=time.monotonic() - started);
}

def _clip(text: str, limit: int) -> str {
    text = " ".join(text.split());
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…";
}
