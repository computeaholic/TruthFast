from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = ROOT / "tests"


def test_no_lines_over_120() -> None:
    offenders: list[str] = []

    for path in ROOT.rglob("*.py"):
        if "artifacts" in str(path):
            continue
        if ".venv" in path.parts:
            continue
        if "tests" in path.parts:
            continue
        if "platform" in path.parts and "runtime" in path.parts:
            continue
        if "scripts" in path.parts and "trust" in path.parts:
            continue
        if path.name.endswith("_pb2.py") or path.name.endswith("_pb2_grpc.py"):
            continue
        if "proto_gen" in path.parts:
            continue
        if path.name == "issue_tier_b_aas.py":
            continue

        text = path.read_text(encoding="utf-8", errors="ignore")
        for i, line in enumerate(text.splitlines(), 1):
            if "sha256:" in line:
                continue
            if "registry.threadforge.local:30500/" in line:
                continue
            if "http://" in line or "https://" in line:
                continue
            if len(line) > 120:
                offenders.append(f"{path}:{i}")

    assert not offenders, "Long lines found:\n" + "\n".join(offenders)
