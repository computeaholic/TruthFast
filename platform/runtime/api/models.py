import uuid

from pydantic import BaseModel

from runtime.smp.schema import SMPEnvelope


class EmbedRequest(BaseModel):
    text: str


class SearchRequest(BaseModel):
    query: str


class InsertRequest(BaseModel):
    id: str
    vector: list[float]


class DeleteRequest(BaseModel):
    id: str


def make_envelope(sender: str, intent: str, payload: dict, identity_ctx: dict | None = None) -> SMPEnvelope:
    """Canonical envelope constructor for runtime.
    SMP is intentionally constrained in this phase.

    Args:
        sender: Actor sending the envelope
        intent: Action intent (search, embed, etc.)
        payload: Request payload
        identity_ctx: Optional identity context dict for ledger attribution
    """
    envelope_payload = {**payload}
    if identity_ctx:
        envelope_payload["_identity_ctx"] = identity_ctx

    # Canonicalize priority to an int at envelope creation (runtime invariant)
    raw_p = envelope_payload.get("priority", 3)
    try:
        p = int(raw_p)
    except Exception:
        p = 3
    envelope_payload["priority"] = p

    return SMPEnvelope(
        envelope_id=str(uuid.uuid4()),
        kind="SMP_REQUEST",
        actor=sender,  # actor, not sender
        intent=intent,
        payload=envelope_payload,
        priority=p,
    )
