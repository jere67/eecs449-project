"""Server entry point.

Every endpoint must be imported here by name, or it answers 404 or 405 (TDD §3, rule 7).
Scheduled jobs are imported here too, so the server registers them at startup.
"""
import from models.health { Health }
import from run.health { health }
import from run.jobs { morning_job }

import from .dashboard.HomePage { HomePage }

def:pub app -> JsxElement {
    <HomePage/>
}
