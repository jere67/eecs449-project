"""Scheduled jobs (TDD §4, daily schedule).

The scheduler reads cron expressions in UTC with day 0 as Monday, so the 7:30 a.m. New York
morning run is registered at both its EDT and EST offsets (11:30 and 12:30 UTC) and proceeds
only when it is 7:30 in New York. The run claims its date before any work, so a second firing
does nothing (TDD §4, idempotency). A static job runs as the system user, which reaches
root.shared (checked by firing a probe job under `jac run`). The post-close job belongs to the
Action phase (#29).
"""
import from datetime { datetime }
import from run.guard { NEW_YORK }
import from run.orchestration { morning_run }

# How late after 7:30 a.m. New York time a firing may start, in minutes; the scheduler can
# fire a few seconds late, never 55 minutes late.
glob FIRING_WINDOW_MINUTES: int = 15;

"""True when `now` (New York time) is the morning run's slot: a weekday between 7:30 and
7:45 a.m. Holidays are left to preflight, which reads the market calendar."""
def morning_slot(now: datetime) -> bool {
    return now.weekday() < 5 and now.hour == 7 and 30 <= now.minute < 30 + FIRING_WINDOW_MINUTES;
}

"""Fires at 11:30 and 12:30 UTC on weekdays; only the firing at 7:30 New York time runs."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="30 11,12 * * 0-4")
def morning_job {
    if morning_slot(datetime.now(NEW_YORK)) {
        morning_run();
    }
}
