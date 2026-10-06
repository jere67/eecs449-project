"""Health endpoint for probes and the dashboard."""
import from datetime { datetime, timezone }
import from models.health { Health }

"""Report that the server is up, stamped with the current UTC time."""
def:pub health -> Health {
    return Health(status="ok", checked_at=datetime.now(timezone.utc).isoformat());
}
