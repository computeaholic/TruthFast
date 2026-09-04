from __future__ import annotations

import hashlib
import json
import time
import uuid
from dataclasses import dataclass
from typing import Any


def _sha3_512_hex(data: bytes) -> str:
    h = hashlib.sha3_512()
    h.update(data)
    return h.hexdigest()


def _stable_json(obj: Any) -> bytes:
    return json.dumps(
        obj,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


@dataclass(frozen=True)
class ActuationProposal:
    """Canonical, immutable proposal emitted by the system.

    This is:
      - logged
      - visualized
      - reviewed
      - approved or rejected

    It is NOT executable by itself.
    """

    proposal_id: str
    created_ts: float
    source: str  # e.g. "reflex_hooks"
    trigger: str  # e.g. "SMP_STARVATION"
    safe: bool

    commands: list[list[str]]  # EXACT commands that would run
    context: dict[str, Any]  # metrics, traces, reasons

    proposal_digest_sha3_512: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "proposal_id": self.proposal_id,
            "created_ts": self.created_ts,
            "source": self.source,
            "trigger": self.trigger,
            "safe": self.safe,
            "commands": self.commands,
            "context": self.context,
            "proposal_digest_sha3_512": self.proposal_digest_sha3_512,
        }


class ActuationProposalBuilder:
    """Builds immutable proposals suitable for:
    - ledger storage
    - Grafana display
    - approval binding
    """

    @staticmethod
    def build(
        *,
        source: str,
        trigger: str,
        commands: list[list[str]],
        context: dict[str, Any],
        safe: bool,
    ) -> ActuationProposal:
        created_ts = time.time()
        proposal_id = f"ap-{uuid.uuid4().hex[:12]}"

        core = {
            "proposal_id": proposal_id,
            "created_ts": created_ts,
            "source": source,
            "trigger": trigger,
            "safe": safe,
            "commands": commands,
            "context": context,
        }

        digest = _sha3_512_hex(_stable_json(core))

        return ActuationProposal(
            proposal_id=proposal_id,
            created_ts=created_ts,
            source=source,
            trigger=trigger,
            safe=safe,
            commands=commands,
            context=context,
            proposal_digest_sha3_512=digest,
        )
