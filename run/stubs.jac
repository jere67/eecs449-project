"""Stubs for a whole run with no network (run/guard.jac, run/orchestration.jac): collection,
the market calendar, OpenRouter's count, and every research brief are stubbed, MockLLM stands
in for every role model, and the run's pool has one worker.

Each scripted model answers every call the same way, so the order calls arrive in never
matters, and every research brief cites one shared source.

The stubs build run types, so they live beside the run modules: `jac build` seals `tests/fakes/`
as a separate dependency, and a `Collection` built there is a different type to the checker."""
import json;
import from concurrent.futures { ThreadPoolExecutor }
import from jaclang.byllm.lib { MockLLM, MockRawResponse }
import agents.arbiter as arbiter_module;
import agents.research as research_module;
import agents.specialists as specialists_module;
import run.guard as guard_module;
import from models.agents { Domain }
import from models.research { Stamp }
import from research.alpaca { MarketDay }
import from research.briefs { Brief, FundamentalsInputs, MacroInputs, MarketInputs, NewsInputs }
import from research.screener { Pick, PickReason, Shortlist }
import from run.research { Collection, PassConfig, TickerInputs }

glob RUN_DAY: str = "2026-10-16";
glob SOURCE: str = "https://example.com/source";
glob SESSIONS: list[str] = ["2026-10-15", "2026-10-16", "2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"];
glob ONE_WORKER: ThreadPoolExecutor = ThreadPoolExecutor(max_workers=1);

glob REPORT_JSON: str = json.dumps({"summary": "Fine.", "view": "BUY", "confidence": 0.6, "evidence": [{"claim": "A fact.", "source_url": SOURCE, "published": "x"}], "risks": ["Rates."], "data_gaps": []});
glob MACRO_JSON: str = json.dumps({"summary": "Calm.", "regime": "NEUTRAL", "confidence": 0.5, "evidence": [{"claim": "SPY rose.", "source_url": SOURCE, "published": "x"}], "risks": [], "data_gaps": []});
glob VOTE_JSON: str = json.dumps({"stance": "STRONG_BUY", "confidence": 0.9, "horizon_days": 5, "rationale": "Strong.", "cited_evidence": [1]});
glob REVIEW_JSON: str = json.dumps({"verdict": "CONFIRM", "reason": "Fine.", "thesis": "Strong.", "risks": ["Valuation.", "Rates."], "exit_condition": "A close below the 50-day average."});

def brief(ticker: str, domain: Domain, as_of: str) -> Brief {
    found = Brief(ticker=ticker, domain=domain, as_of=as_of);
    found.add(f"{ticker} {domain.value}", SOURCE, "2026-10-15", "Some data.");
    return found;
}

def stub_briefs(run_day: str, inputs: TickerInputs) -> dict[Domain, Brief] {
    return {d: brief(inputs.pick.symbol, d, run_day) for d in [Domain.MARKET, Domain.FUNDAMENTALS, Domain.NEWS]};
}

def stub_macro_brief(as_of: str, _inputs: MacroInputs) -> Brief {
    return brief("MARKET", Domain.MACRO, as_of);
}

def collection(symbols: list[str], held: list[str]) -> Collection {
    picks = [Pick(symbol=s, sector="Information Technology", reason=PickReason.SCORE, score=1.0) for s in symbols];
    picks.extend(Pick(symbol=s, sector="Energy", reason=PickReason.OPEN_POSITION, note="open position") for s in held if s not in symbols);
    return Collection(
        run_day=RUN_DAY,
        started_at="2026-10-16T11:30:00+00:00",
        shortlist=Shortlist(picks=picks, scores=[], excluded={}),
        tickers=[TickerInputs(pick=p, market=MarketInputs(), fundamentals=FundamentalsInputs(), news=NewsInputs()) for p in picks],
        macro_inputs=MacroInputs(),
        sessions=SESSIONS
    );
}

def calendar_day(day: str) -> MarketDay {
    return MarketDay(day=day, open="09:30", close="16:00", early_close=False, stamp=Stamp(source="alpaca_trading", dataset="alpaca.calendar", source_url="u", published_at=day, fetched_at=day));
}

"""Every stub and mock a run needs, installed on the modules that look them up, and put back
by `restore`."""
obj Stubs {
    has symbols: list[str] = ["AAPL", "MSFT"],
        provider_left: int | None = 900,
        trading: bool = True,
        collect_error: str = "",
        shortlist_sizes: list[int] = [];
    has research_llm: MockLLM | None = None,
        specialist_llm: MockLLM | None = None,
        arbiter_llm: MockLLM | None = None,
        saved: list[tuple[object, str, object]] = [];

    def install {
        self.research_llm = MockLLM(model_name="mock-research", config={"outputs": [MockRawResponse(content=REPORT_JSON)] * 40});
        self.specialist_llm = MockLLM(model_name="mock-specialist", config={"outputs": [MockRawResponse(content=VOTE_JSON)] * 200});
        self.arbiter_llm = MockLLM(model_name="mock-arbiter", config={"outputs": [MockRawResponse(content=REVIEW_JSON)] * 10});
        macro_llm = MockLLM(model_name="mock-macro", config={"outputs": [MockRawResponse(content=MACRO_JSON)]});
        stubs = self;
        def collect(_run_day: str, open_positions: list[str], config: PassConfig) -> Collection {
            stubs.shortlist_sizes.append(config.screen.shortlist_size);
            if stubs.collect_error {
                raise RuntimeError(stubs.collect_error);
            }
            return collection(stubs.symbols, open_positions);
        }
        def calendar(start: str, _end: str, _budget: object) -> list[MarketDay] {
            return [calendar_day(start)] if stubs.trading else [];
        }
        def macro_research(b: Brief) -> object {
            saved_llm = research_module.research_llm;
            setattr(research_module, "research_llm", macro_llm);
            try {
                return research_module.macro_research(b);
            } finally {
                setattr(research_module, "research_llm", saved_llm);
            }
        }
        self._swap(guard_module, "collect_pass", collect);
        self._swap(guard_module, "market_calendar", calendar);
        self._swap(guard_module, "provider_requests_left", lambda { stubs.provider_left; });
        self._swap(guard_module, "briefs_for", stub_briefs);
        self._swap(guard_module, "macro_brief", stub_macro_brief);
        self._swap(guard_module, "macro_research", macro_research);
        self._swap(guard_module, "NETWORK", ONE_WORKER);
        self._swap(research_module, "research_llm", self.research_llm);
        self._swap(specialists_module, "specialist_llm", self.specialist_llm);
        self._swap(arbiter_module, "arbiter_llm", self.arbiter_llm);
    }

    def _swap(module: object, name: str, value: object) {
        self.saved.append((module, name, getattr(module, name)));
        setattr(module, name, value);
    }

    def restore {
        for (module, name, value) in reversed(self.saved) {
            setattr(module, name, value);
        }
        self.saved = [];
    }
}
