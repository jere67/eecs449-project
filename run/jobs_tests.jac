"""The morning job's New York time check, at both UTC firings across the clock change."""
import from datetime { datetime, timezone }
import from run.guard { NEW_YORK }
import from run.jobs { morning_slot }

def at(utc: str) -> datetime {
    return datetime.fromisoformat(utc).replace(tzinfo=timezone.utc).astimezone(NEW_YORK);
}

test "in daylight time the 11:30 UTC firing runs and the 12:30 one does not" {
    assert morning_slot(at("2026-10-16T11:30:00"));
    assert not morning_slot(at("2026-10-16T12:30:00"));
}

test "in standard time the 12:30 UTC firing runs and the 11:30 one does not" {
    assert morning_slot(at("2026-11-02T12:30:00"));
    assert not morning_slot(at("2026-11-02T11:30:00"));
}

test "a late firing inside the window runs, and weekends never do" {
    assert morning_slot(at("2026-10-16T11:44:59"));
    assert not morning_slot(at("2026-10-16T11:45:00"));
    assert not morning_slot(at("2026-10-17T11:30:00"));
}
