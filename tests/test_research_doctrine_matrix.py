import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MATRIX = ROOT / "docs/architecture/system-model/research_doctrine_matrix.json"
SOURCE = (
    ROOT
    / "reports/research/threadforge-failed-assumption-doctrine-20260828/README.md"
)

EXPECTED_IDS = [chr(code) for code in range(ord("A"), ord("Z") + 1)] + [
    f"A{chr(code)}" for code in range(ord("A"), ord("I") + 1)
]
VALID_STATUSES = {
    "VALIDATED_STRENGTH",
    "ARCHITECTURAL_ALIGNMENT",
    "VALIDATION_INCOMPLETE",
    "GAP_IDENTIFIED",
    "POST_V1",
    "WATCH_ITEM",
    "NOT_APPLICABLE",
    "VOCABULARY_MISMATCH",
}


def _matrix() -> dict:
    return json.loads(MATRIX.read_text(encoding="utf-8"))


def test_doctrine_matrix_has_exactly_the_35_reviewed_laws() -> None:
    data = _matrix()
    laws = data["laws"]
    ids = [law["law_id"] for law in laws]

    assert ids == EXPECTED_IDS
    assert len(ids) == len(set(ids)) == 35
    assert sum(data["status_summary"].values()) == 35


def test_doctrine_statuses_and_required_ownership_are_explicit() -> None:
    data = _matrix()
    observed = {status: 0 for status in VALID_STATUSES}

    for law in data["laws"]:
        assert law["threadforge_status"] in VALID_STATUSES
        observed[law["threadforge_status"]] += 1
        assert law["current_v1_invariant"].strip()
        assert law["current_owner"].strip()
        assert law["evidence"]
        assert law["confidence"] in {"HIGH", "MEDIUM", "LOW"}
        assert law["action"] in {"NONE", "WATCH", "POST_V1"}

    assert data["status_summary"] == observed


def test_post_v1_and_watch_laws_do_not_become_v1_obligations() -> None:
    laws = {law["law_id"]: law for law in _matrix()["laws"]}

    assert {law_id for law_id, law in laws.items() if law["post_v1"]} == {
        "K",
        "AE",
    }
    assert {law_id for law_id, law in laws.items() if law["threadforge_status"] == "WATCH_ITEM"} == {
        "AC",
        "AH",
    }
    assert {
        law_id
        for law_id, law in laws.items()
        if law["threadforge_status"] == "VALIDATION_INCOMPLETE"
    } == {"E", "G", "R"}
    assert not any(
        law["threadforge_status"] == "GAP_IDENTIFIED" for law in laws.values()
    )


def test_forensic_source_preserves_every_law_body() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    for law_id in EXPECTED_IDS:
        assert f"## Law {law_id} -" in source


def test_license_inventory_covers_all_tracked_binaries() -> None:
    notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    binaries = [
        "internal/control/identity/identity-controller/bin/controller-gen",
        "platform/build/csi-rebuild/csi-node-shim",
        "platform/build/csi-reg/csi-node-reg-proxy",
        "platform/cmd/csi-node-shim/csi-node-shim",
        "platform/cmd/csi-reg-shim/csi-node-reg-proxy",
        "platform/cmd/csi-reg-shim/csi-reg-shim",
        "platform/cmd/threadforge-notifier/threadforge-notifier",
    ]
    expected_hashes = {
        "internal/control/identity/identity-controller/bin/controller-gen": (
            "5328ad87bdb386d98f2f3e3fe40b080ab0fbde455c03a618b495bbb9d19aa6c8"
        ),
        "platform/build/csi-rebuild/csi-node-shim": "08d9e37a18c45c6de9fefcca6aaa2dd4d2d9a42cd4e460e8f350674d2d067653",
        "platform/build/csi-reg/csi-node-reg-proxy": "b6b2623dd815af6ed2fc0be1405e249a8e375389c412750da349f96a59059a05",
        "platform/cmd/csi-node-shim/csi-node-shim": "b3912e5f873fd7a5285cc6291457a487dc8b6ba12142bbc243830bcbdb13bf1c",
        "platform/cmd/csi-reg-shim/csi-node-reg-proxy": (
            "b6b2623dd815af6ed2fc0be1405e249a8e375389c412750da349f96a59059a05"
        ),
        "platform/cmd/csi-reg-shim/csi-reg-shim": "2a70c7f098b3074ca058fe0362cb7c67426e017fab20df38392ce7140ef98178",
        "platform/cmd/threadforge-notifier/threadforge-notifier": (
            "74821d23287f8c6122bbb09af8e1459491a90685881e7ed3b16bd8ae6daffbe3"
        ),
    }

    assert (ROOT / "LICENSE").read_text(encoding="utf-8").startswith(
        "# PolyForm Shield License 1.0.0\n"
    )
    assert all(path in notices for path in binaries)
    assert "Apache-2.0 Components" in notices
    assert "BSD-3-Clause Components" in notices
    assert "MIT Components" in notices

    tracked = subprocess.check_output(
        ["git", "ls-files", "-z"], cwd=ROOT
    ).decode().split("\0")
    compiled = {
        path
        for path in tracked
        if path
        and (ROOT / path).read_bytes()[:4]
        in {b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}
    }
    assert compiled == set(binaries)
    assert {
        path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
        for path in binaries
    } == expected_hashes

    topology = (
        ROOT / "scripts/verify/verify_repository_topology.sh"
    ).read_text(encoding="utf-8")
    assert '"LICENSE"' in topology
    assert '"THIRD_PARTY_NOTICES.md"' in topology
    assert "! -name 'THIRD_PARTY_NOTICES.md'" in topology
    assert '"docs/architecture/ENGINEERING_DOCTRINE.md"' in topology
    assert '"docs/architecture/system-model/research_doctrine_matrix.json"' in topology

    governance = json.loads(
        (ROOT / ".github/governance/THREADFORGE_GOVERNANCE.json").read_text(
            encoding="utf-8"
        )
    )
    allowed_root_files = governance["filesystem_policy"]["allowed_root_files"]
    assert "LICENSE" in allowed_root_files
    assert "THIRD_PARTY_NOTICES.md" in allowed_root_files

    pre_commit = (ROOT / ".githooks/pre-commit").read_text(encoding="utf-8")
    assert "LICENSE THIRD_PARTY_NOTICES.md" in pre_commit
