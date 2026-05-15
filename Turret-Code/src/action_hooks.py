"""Action hooks invoked by external interfaces (web API, future inputs)."""

from __future__ import annotations

from datetime import datetime, timezone


def shoot() -> dict:
    """Placeholder action for the /shoot API.

    Replace this with your actual firing logic later.
    """
    return {
        "status": "noop",
        "message": "Shoot endpoint reached. Replace action_hooks.shoot() with real logic.",
        "ts_utc": datetime.now(timezone.utc).isoformat(),
    }
