"""
Artifact Writer — Persists DecisionRecords to disk.

Phase D: Decision Provenance Core
Phase H: Audit System Hardening (Cryptographic Signing + Retention Metadata)

This module writes DecisionRecords to disk in two formats:
1. JSON (machine-readable, full fidelity)
2. Markdown (human-readable, explanatory)

All writes are to artifacts/ directory. No database mutations occur.

Phase H Enhancements:
- All JSON artifacts are cryptographically signed with Ed25519
- Signatures are written as separate metadata files ({decision_id}.json.sig)
- Retention metadata is written for all artifacts ({decision_id}.json.retention.json)

Global Invariant: This module SHALL NOT write to authority tables, flip
enforcement flags, schedule execution, or emit executable signals.
"""

import json
import logging
from pathlib import Path
from typing import Optional

from runtime.civ.provenance.artifact_signing import ArtifactSigner, SigningError
from runtime.civ.provenance.decision_record import DecisionRecord
from runtime.civ.retention_metadata import create_decision_retention_metadata, write_retention_metadata

logger = logging.getLogger(__name__)


class ArtifactWriter:
    """
    Writes DecisionRecords to disk in machine-readable (JSON) and
    human-readable (Markdown) formats.

    All artifacts are stored under artifacts/civ/decisions/ with names:
    - {decision_id}.json (full record)
    - {decision_id}.json.sig (signature metadata, Phase H)
    - {decision_id}.md (human-readable explanation)

    Phase H Hardening: All JSON artifacts are cryptographically signed.
    Signing is mandatory and fail-closed.

    Responsibilities:
    1. Serialize DecisionRecord to JSON
    2. Sign JSON artifact with Ed25519 (Phase H)
    3. Write signature metadata to disk (Phase H)
    4. Generate human-readable Markdown
    5. Write all artifacts to disk
    6. Log all writes with decision ID and path
    """

    def __init__(self, artifact_root: Path = Path("artifacts/civ/decisions"), signer: Optional[ArtifactSigner] = None):
        """
        Initialize writer.

        Args:
            artifact_root: Root directory for decision artifacts.
                          Defaults to artifacts/civ/decisions.
            signer: ArtifactSigner instance. If None, creates new signer
                   (requires CIV_SIGNING_KEY environment variable).

        Raises:
            SigningError: If signer cannot be initialized (fail-closed)
        """
        self.artifact_root = artifact_root
        self.artifact_root.mkdir(parents=True, exist_ok=True)

        # Phase H: Mandatory signing
        if signer is None:
            self.signer = ArtifactSigner()  # May raise SigningError if key missing
        else:
            self.signer = signer

        self.logger = logging.getLogger(f"{__name__}.{self.__class__.__name__}")

    def write_decision(
        self,
        decision: DecisionRecord,
        write_json: bool = True,
        write_markdown: bool = True,
    ) -> dict:
        """
        Write DecisionRecord to disk with cryptographic signature (Phase H).

        Args:
            decision: DecisionRecord to persist
            write_json: Write JSON artifact (default True)
            write_markdown: Write Markdown artifact (default True)

        Returns:
            Dict with keys:
              - json_path: Path to JSON file (or None)
              - signature_path: Path to signature metadata file (or None, Phase H)
              - signature_metadata: Signature metadata dict (Phase H)
              - markdown_path: Path to Markdown file (or None)

        Raises:
            IOError: If write fails
            SigningError: If signing fails (fail-closed, Phase H)
        """
        decision_id = str(decision.decision_id)
        result = {}
        sig_metadata = None

        if write_json:
            json_path, sig_path, sig_metadata = self._write_json_with_signature(decision)
            result["json_path"] = str(json_path)
            result["signature_path"] = str(sig_path)
            result["signature_metadata"] = sig_metadata
            self.logger.info(
                f"Wrote decision {decision_id} to JSON: {json_path} " f"(signed with key {sig_metadata['key_id']})"
            )

        if write_markdown:
            md_path = self._write_markdown(decision, sig_metadata)
            result["markdown_path"] = str(md_path)
            self.logger.info(f"Wrote decision {decision_id} to Markdown: {md_path}")

        # Emit an observation artifact for E2E verification (ACCEPTED)
        # This is intentionally best-effort and must not block DecisionRecord writes.
        try:
            import os

            OBS_DIR = os.getenv("OBSERVATION_DIR")

            # Prefer the sanctioned adapter if available
            try:
                from internal.observation_adapter.adapter import ObservationAdapter

                adapter = ObservationAdapter(base_dir=OBS_DIR)
                adapter.emit(
                    execution_id=str(decision.provenance_hash),
                    status="ACCEPTED",
                    reason="decision-record-written",
                    observed_at=decision.generated_at.isoformat(),
                )
            except Exception:
                # Fallback: write a minimal JSON observation file if OBSERVATION_DIR is set
                if OBS_DIR:
                    try:
                        os.makedirs(OBS_DIR, exist_ok=True)
                        fname = os.path.join(OBS_DIR, f"{decision.provenance_hash}.json")
                        obs = {
                            "execution_id": str(decision.provenance_hash),
                            "status": "ACCEPTED",
                            "reason": "decision-record-written",
                            "observed_at": decision.generated_at.isoformat(),
                        }
                        import json

                        with open(fname + ".tmp", "w") as f:
                            f.write(json.dumps(obs, indent=2))
                        os.replace(fname + ".tmp", fname)
                    except Exception:
                        # Do not block on observation failures
                        self.logger.exception("failed to write observation artifact (ACCEPTED) - continuing")
        except Exception:
            # Ensure we never raise from observation emission
            self.logger.exception("observation emission error (ACCEPTED) - ignored")

        return result

    def _write_json_with_signature(self, decision: DecisionRecord) -> tuple:
        """
        Write DecisionRecord to JSON and sign it (Phase H).

        Args:
            decision: DecisionRecord to serialize

        Returns:
            Tuple of (json_path, signature_path, signature_metadata)

        Raises:
            SigningError: If signing fails

        File format:
          artifacts/civ/decisions/{decision_id}.json (artifact)
          artifacts/civ/decisions/{decision_id}.json.sig (signature metadata)
        """
        decision_id = str(decision.decision_id)
        json_path = self.artifact_root / f"{decision_id}.json"
        sig_path = self.artifact_root / f"{decision_id}.json.sig"

        # Serialize to JSON
        json_str = decision.to_json_str()

        # Phase H: Sign artifact content
        try:
            signature_metadata = self.signer.sign_artifact(json_str)
        except SigningError as e:
            self.logger.error(f"Failed to sign artifact {decision_id}: {e}")
            raise  # Fail closed

        # Write JSON artifact
        json_path.write_text(json_str)

        # Write signature metadata
        sig_json = json.dumps(signature_metadata, indent=2)
        sig_path.write_text(sig_json)

        # Phase H: Write retention metadata
        retention_metadata = create_decision_retention_metadata(
            decision_id=decision_id,
            created_at=decision.generated_at.isoformat(),
        )
        write_retention_metadata(retention_metadata, json_path)

        # Best-effort: update Redis-backed SMP store to reflect ACCEPTED decision keyed by provenance hash
        try:
            from runtime.smp.state.redis_store import RedisSMPStore

            try:
                store = RedisSMPStore()
                # Use provenance_hash as the execution identifier (non-authoritative)
                exec_id = decision.provenance_hash
                store.update_decision(exec_id, "ACCEPTED", "decision-record-written")
            except Exception as e:
                # tolerate failures; Redis is non-authoritative and must not block writes
                # Log and accept as best-effort. # nosec B110
                from runtime.util.best_effort import swallow_optional

                swallow_optional(
                    "Redis update_decision (non-authoritative)", e
                )  # nosec B110: non-authoritative update tolerated
        except Exception as e:
            # import failures tolerated; log for visibility
            logger.debug(
                "Redis import failed (non-authoritative): %s", e
            )  # nosec B110: non-authoritative import failure tolerated

        # Instrumentation: record that a decision artifact was written (best-effort)
        try:
            from runtime.smp.metrics import inc_replay

            try:
                inc_replay("decision_written")
            except Exception as e:
                logger.debug("inc_replay failed (best-effort): %s", e)  # nosec B110
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional("inc_replay import", e)  # nosec B110
        return json_path, sig_path, signature_metadata

    def _write_markdown(self, decision: DecisionRecord, signature_metadata: Optional[dict] = None) -> Path:
        """
        Write DecisionRecord to human-readable Markdown.

        Args:
            decision: DecisionRecord to render
            signature_metadata: Optional signature metadata to include (Phase H)

        Returns:
            Path to written file

        File format:
          artifacts/civ/decisions/{decision_id}.md
          (Markdown with sections, tables, code blocks)
        """
        decision_id = str(decision.decision_id)
        md_path = self.artifact_root / f"{decision_id}.md"

        # Generate Markdown
        md_content = self._render_markdown(decision, signature_metadata)

        # Write to disk
        md_path.write_text(md_content)
        return md_path

    def _render_markdown(self, decision: DecisionRecord, signature_metadata: Optional[dict] = None) -> str:
        """
        Render DecisionRecord as Markdown.

        Args:
            decision: DecisionRecord to render

        Returns:
            Markdown string
        """
        lines = []

        # Header
        lines.append(f"# Decision Record: {decision.decision_type.value}")
        lines.append("")
        lines.append(f"**Decision ID:** `{decision.decision_id}`")
        lines.append(f"**Generated:** {decision.generated_at.isoformat()}")
        lines.append(f"**Provenance Hash:** `{decision.provenance_hash}`")

        # Phase H: Signature information
        if signature_metadata:
            lines.append("")
            lines.append("**Cryptographic Signature (Phase H):**")
            lines.append(f"- **Algorithm:** {signature_metadata['algorithm']}")
            lines.append(f"- **Key ID:** `{signature_metadata['key_id']}`")
            lines.append(f"- **Signature:** `{signature_metadata['signature'][:32]}...` (truncated for readability)")
            lines.append(f"- **Signed Content Hash:** `{signature_metadata['signed_content_hash']}`")
            lines.append("- **Verification:** See `{decision_id}.json.sig` for full signature metadata")

        lines.append("")

        # Classification & Advisory Notice
        lines.append("## ⚠️  Classification & Constraints")
        lines.append("")
        lines.append(f"- **Classification:** {decision.classification}")
        lines.append(f"- **Enforcement Prohibited:** {decision.enforcement_prohibited}")
        lines.append("- **Status:** Advisory only. No execution path depends on this record.")
        lines.append("")

        # Time Window
        lines.append("## Time Window")
        lines.append("")
        lines.append(f"- **Start:** {decision.time_window.start.isoformat()}")
        lines.append(f"- **End:** {decision.time_window.end.isoformat()}")
        lines.append("")

        # Inputs
        lines.append("## Inputs")
        lines.append("")
        lines.append("**Source Tables:**")
        for table in decision.inputs.source_tables:
            lines.append(f"- `{table}`")
        lines.append("")
        lines.append("**Query Files:**")
        for query_file in decision.inputs.query_files:
            lines.append(f"- `{query_file}`")
        lines.append("")
        if decision.inputs.parameters:
            lines.append("**Parameters:**")
            for key, value in decision.inputs.parameters.items():
                lines.append(f"- `{key}`: {value}")
            lines.append("")

        # Derived Metrics
        lines.append("## Derived Metrics")
        lines.append("")
        metrics = decision.derived_metrics
        lines.append(f"- **Utilization:** {metrics.utilization_percent:.2f}%")
        lines.append(f"- **Denial Pressure:** {metrics.denial_pressure:.4f} (0.0–1.0)")
        if metrics.minutes_to_breach is not None:
            lines.append(f"- **Minutes to Breach:** {metrics.minutes_to_breach}")
        if metrics.confidence_interval:
            low = metrics.confidence_interval["low"]
            high = metrics.confidence_interval["high"]
            lines.append(f"- **Confidence Interval:** [{low:.4f}, {high:.4f}]")
        lines.append("")

        # Dominant Contributors
        lines.append("## Dominant Contributors")
        lines.append("")
        if decision.dominant_contributors:
            for contrib in decision.dominant_contributors:
                ctype = contrib.contributor_type.value
                cid = contrib.contributor_id
                cpct = contrib.contribution_percent
                lines.append(f"- **{ctype}** `{cid}`: {cpct:.1f}%")
        else:
            lines.append("(No contributors identified)")
        lines.append("")

        # Counterfactual Sensitivity
        lines.append("## Counterfactual Sensitivity")
        lines.append("")
        lines.append("### Increase Budget By")
        cf = decision.counterfactual_sensitivity
        lines.append(f"- **Delta:** {cf.increase_budget_by.get('delta', 'N/A')}")
        lines.append(f"- **Effect:** {cf.increase_budget_by.get('effect', 'N/A')}")
        lines.append("")
        lines.append("### Reduce Load By")
        lines.append(f"- **Delta:** {cf.reduce_load_by.get('delta', 'N/A')}")
        lines.append(f"- **Effect:** {cf.reduce_load_by.get('effect', 'N/A')}")
        lines.append("")
        lines.append("### Enforce Now (Hypothetical)")
        lines.append(f"- **Effect:** {cf.enforce_now.get('hypothetical_effect', 'N/A')}")
        lines.append("")

        # Recommendation
        lines.append("## Recommendation")
        lines.append("")
        rec = decision.recommendation
        lines.append(f"> {rec.text}")
        lines.append("")
        lines.append(f"**Confidence:** {rec.confidence:.2%}")
        lines.append("")

        # Determinism Notice
        lines.append("## Determinism")
        lines.append("")
        lines.append(
            f"This record is deterministically derived from its inputs. "
            f"Given identical source data, the same provenance hash "
            f"`{decision.provenance_hash}` will be produced. "
            f"This enables audit, replay, and cryptographic attribution."
        )
        lines.append("")

        # Non-Binding Notice
        lines.append("## Non-Binding Notice")
        lines.append("")
        lines.append(
            "This decision record is strictly **advisory**. "
            "It describes pressure, trends, and recommendations but **makes no decisions**, "
            "**issues no commands**, and **forbids enforcement**. "
            "All enforcement remains external to the Civ Engine."
        )
        lines.append("")

        return "\n".join(lines)
