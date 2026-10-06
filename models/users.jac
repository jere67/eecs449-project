"""Per-user graph on each signed-in user's own root (TDD §11).

    user root
      ├─ UserProfile
      └─ ReportRequest ──Uses──> Coverage (the shared daily cache on root.shared)

This module's path is frozen for the same reason as models/graph.jac.
"""
import from models.graph { Coverage }

enum ReportStatus: str {
    PENDING = "pending",
    RUNNING = "running",
    READY = "ready",
    FAILED = "failed"
}

node UserProfile {
    has created_at: str;
}

node ReportRequest {
    has ticker: str,
        trading_date: str,
        requested_at: str;
    has status: ReportStatus = ReportStatus.PENDING,
        error: str = "";
}

edge Uses: ReportRequest --> Coverage {}
