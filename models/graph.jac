"""The team graph on root.shared (TDD §11).

    root.shared
      └─ Portfolio
           ├─ Holds ──> Position ──OpenedBy──> Decision
           └─ Ran ──> Run(run_date)
                ├─ HasMacro ──> MacroRecord
                └─ Covers ──> Coverage(ticker)
                     ├─ Researched ──> ResearchRecord (one per domain)
                     ├─ Voted ──> VoteRecord (one per specialist sample)
                     ├─ Concluded ──> ConsensusResult
                     ├─ Decided ──> Decision ──CheckedBy──> RiskCheck ──Placed──> Order ──FilledBy──> Fill
                     └─ Published ──> InsightCard

This module's path is frozen: moving a node type to another module quarantines its stored
rows until a schema rule maps the old path (TDD §11, schema changes). Add fields with
defaults freely; rename fields only with schema_alias.

Timestamps are ISO 8601 strings in UTC, and trading dates are "YYYY-MM-DD" in New York time
(TDD §3, rule 11).
"""
import from models.agents { Domain, MacroReport, ResearchReport, Specialist, Vote }

enum PortfolioMode: str {
    AUTO = "auto",
    INSIGHT = "insight"
}

enum RunStatus: str {
    RUNNING = "running",
    NORMAL = "normal",
    FALLBACK = "fallback",
    SKIPPED = "skipped",
    FAILED = "failed"
}

enum CoverageReason: str {
    SCREEN = "screen",
    HELD = "held",
    WILDCARD = "wildcard",
    USER_REQUEST = "user_request"
}

enum TradeAction: str {
    BUY = "BUY",
    ADD = "ADD",
    HOLD = "HOLD",
    TRIM = "TRIM",
    SELL = "SELL",
    NO_ACTION = "NO_ACTION"
}

enum RiskOutcome: str {
    APPROVED = "approved",
    RESIZED = "resized",
    REJECTED = "rejected"
}

enum OrderSide: str {
    BUY = "buy",
    SELL = "sell"
}

enum OrderPurpose: str {
    ENTRY = "entry",
    ADD = "add",
    EXIT = "exit",
    TRIM = "trim",
    STOP = "stop"
}

node Portfolio {
    has name: str,
        mode: PortfolioMode,
        starting_cash: float,
        opened_at: str;
    has peak_equity: float = 0.0;
}

node Position {
    has ticker: str,
        sector: str,
        qty: int,
        avg_entry_price: float,
        opened_at: str;
    has stop_price: float = 0.0,
        stop_order_id: str = "";
}

node Run {
    has run_date: str,
        started_at: str;
    has status: RunStatus = RunStatus.RUNNING,
        reduced_mode: bool = False,
        finished_at: str = "",
        summary: str = "",
        model_versions: dict[str, str] = {},
        model_requests: int = 0,
        prompt_tokens: int = 0,
        completion_tokens: int = 0;
}

node MacroRecord {
    has as_of: str,
        model: str,
        body: MacroReport;
}

node Coverage {
    has ticker: str,
        sector: str,
        reason: CoverageReason;
    has screen_score: float = 0.0,
        reason_note: str = "",
        fetch_errors: list[str] = [],
        flag_reason: str = "";
}

node ResearchRecord {
    has ticker: str,
        domain: Domain,
        as_of: str,
        model: str,
        body: ResearchReport;
    has followup_question: str = "";
}

node VoteRecord {
    has ticker: str,
        specialist: Specialist,
        sample: int,
        model: str,
        body: Vote;
    has excess_return: float | None = None,
        scored_at: str = "";
}

node ConsensusResult {
    has ticker: str,
        score: float,
        agreement: float,
        ci_low: float,
        ci_high: float,
        draft_action: TradeAction;
    has specialist_scores: dict[str, float] = {},
        weights: dict[str, float] = {},
        samples_used: int = 0,
        samples_dropped: int = 0;
}

node Decision {
    has ticker: str,
        action: TradeAction,
        conviction: float;
    has thesis: str = "",
        risks: list[str] = [],
        exit_condition: str = "",
        time_stop: str = "",
        downgrade_reason: str = "",
        forced_hold_reason: str = "";
}

obj RuleResult {
    has rule: str,
        passed: bool;
    has detail: str = "",
        qty_before: int = 0,
        qty_after: int = 0;
}

node RiskCheck {
    has outcome: RiskOutcome,
        approved_qty: int,
        checked_at: str;
    has rules: list[RuleResult] = [];
}

node Order {
    has client_order_id: str,
        purpose: OrderPurpose,
        side: OrderSide,
        qty: int,
        order_type: str,
        time_in_force: str,
        submitted_at: str;
    has alpaca_order_id: str = "",
        limit_price: float = 0.0,
        stop_price: float = 0.0,
        status: str = "new",
        reject_reason: str = "";
}

node Fill {
    has qty: int,
        price: float,
        filled_at: str;
}

node InsightCard {
    has ticker: str,
        action: TradeAction,
        conviction: float,
        published_at: str;
}

edge Holds: Portfolio --> Position {}
edge OpenedBy: Position --> Decision {}
edge Ran: Portfolio --> Run {}
edge HasMacro: Run --> MacroRecord {}
edge Covers: Run --> Coverage {}
edge Researched: Coverage --> ResearchRecord {}
edge Voted: Coverage --> VoteRecord {}
edge Concluded: Coverage --> ConsensusResult {}
edge Decided: Coverage --> Decision {}
edge CheckedBy: Decision --> RiskCheck {}
edge Placed: RiskCheck --> Order {}
edge FilledBy: Order --> Fill {}
edge Published: Coverage --> InsightCard {}
