#!/usr/bin/env python3
"""Focused tests for canonical Mermaid generation."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import pytest

from scripts.generate_mermaids import (
    generate_diagrams,
    generate_forgesec_flow,
    generate_master_system_diagram,
    load_evidence,
)

pytestmark = pytest.mark.unit


class TestGenerateMermaids(unittest.TestCase):
    def test_load_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            audit_dir = Path(tmpdir)
            evidence_file = audit_dir / "raw" / "phase_identity.json"
            evidence_file.parent.mkdir(parents=True, exist_ok=True)
            evidence_file.write_text(json.dumps({"phase": "identity", "evidence": {"spire_dir_present": True}}))

            evidence = load_evidence(audit_dir)
            self.assertIn("identity", evidence)
            self.assertTrue(evidence["identity"]["evidence"]["spire_dir_present"])

    def test_generate_diagrams_under_artifacts_mermaid_without_ppit(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            audit_dir = repo_root / "artifacts" / "audit" / "20260417T000000Z"
            output_dir = repo_root / "artifacts" / "mermaid" / "20260417T000000Z"
            (audit_dir / "raw").mkdir(parents=True, exist_ok=True)
            (audit_dir / "raw" / "phase_identity.json").write_text(
                json.dumps(
                    {"phase": "identity", "evidence": {"spire_dir_present": True, "spire_namespace_present": True}}
                )
            )
            (audit_dir / "raw" / "phase_repo_authority.json").write_text(
                json.dumps({"phase": "repo_authority", "status": "PASS", "evidence": {"root_leaks": []}})
            )

            written = generate_diagrams(audit_dir, output_dir)

            self.assertTrue(written)
            self.assertTrue(str(output_dir).endswith("artifacts/mermaid/20260417T000000Z"))
            for path in written:
                self.assertTrue(path.exists())
                self.assertEqual(path.parent, output_dir)
                content = path.read_text()
                self.assertTrue(content.strip())
                self.assertTrue(content.startswith("graph "))
                self.assertNotIn("ppit", content.lower())

    def test_generate_forgesec_flow_uses_canonical_artifact_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            output_file = Path(tmpdir) / "forgesec_flow.mmd"
            generate_forgesec_flow(
                {"forgesec": {"evidence": {"suite_manifests_present": True, "registry_host_current": True}}},
                output_file,
            )

            content = output_file.read_text()
            self.assertIn("artifacts/forgesec/<run>", content)
            self.assertNotIn("ppit", content.lower())

    def test_generate_master_system_diagram_tracks_canonical_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            output_file = Path(tmpdir) / "master_system.mmd"
            generate_master_system_diagram({"repo_authority": {"status": "PASS"}}, output_file)

            content = output_file.read_text()
            self.assertIn("artifacts/audit", content)
            self.assertIn("artifacts/mermaid", content)
            self.assertIn("artifacts/runtime", content)
            self.assertNotIn("ppit", content.lower())


if __name__ == "__main__":
    unittest.main()
