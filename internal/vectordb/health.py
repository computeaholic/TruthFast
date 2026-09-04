"""ThreadForge — VectorDB Health Monitor
Used by Operator-AI and SMP heartbeat.
"""

from typing import TYPE_CHECKING

import httpx

# Integration-only imports: deferred to prevent unit test collection failure
if TYPE_CHECKING:
    pass


class VectorHealth:
    def pg(self, conn_str: str) -> bool:
        # Integration-only imports: deferred to runtime
        import psycopg

        try:
            with psycopg.connect(conn_str) as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1;")
            return True
        except Exception:
            return False

    def qdrant(self, base_url: str) -> bool:
        try:
            resp = httpx.get(f"{base_url.rstrip('/')}/collections")
            return resp.status_code == 200
        except Exception:
            return False
