"""Read API Surface

Internal-only read endpoints.
SELECT-only access via ledger_reader.
"""

import uuid
from datetime import datetime

from fastapi import FastAPI, Query

from runtime.interpretation.interpret_operator_events import interpret_operator_event
from runtime.interpretation.interpret_value_events import interpret_value_event
from runtime.ledger_reader import fetch_operator_events, fetch_value_events

app = FastAPI(
    title="ThreadForge Read API",
    version="1.0",
)


@app.get("/operator-events")
def get_operator_events(
    limit: int = Query(100, ge=1, le=1000),
    after_event_id: uuid.UUID | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
):
    events = fetch_operator_events(
        limit=limit,
        after_event_id=after_event_id,
        since=since,
        until=until,
    )
    return [interpret_operator_event(e) for e in events]


@app.get("/value-events")
def get_value_events(
    limit: int = Query(100, ge=1, le=1000),
    after_event_id: uuid.UUID | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
    identity_class: str | None = Query(None, regex="^(native|translated|bridged|ephemeral)$"),
):
    events = fetch_value_events(
        limit=limit,
        after_event_id=after_event_id,
        since=since,
        until=until,
        identity_class=identity_class,
    )
    return [interpret_value_event(e) for e in events]
