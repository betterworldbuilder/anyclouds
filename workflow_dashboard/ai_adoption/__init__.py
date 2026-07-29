"""Stage 9 — AI Adoption & Production Factory.

Additive to the existing client-side Stage 9 (_ai_powerup.html): this package
adds the server side needed to import a real project, scan it without executing
it, score its production gaps honestly, and emit a handoff Rackspace operations
can act on.

Disabled wholesale by AI_ADOPTION_FACTORY_ENABLED=0, in which case app.py never
registers the blueprint and Stage 9 behaves exactly as it did before.
"""

from .models import ADOPTION_MODES, SOURCE_TYPES, STATUSES, new_project
from .store import ProjectStore

__all__ = ["ADOPTION_MODES", "SOURCE_TYPES", "STATUSES", "new_project", "ProjectStore"]
