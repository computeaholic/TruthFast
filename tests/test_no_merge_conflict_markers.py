import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit


def _git_tracked_files(repo_root: Path) -> list[Path]:
    proc = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=str(repo_root),
        check=True,
        capture_output=True,
    )
    raw = proc.stdout
    paths = [p for p in raw.split(b"\x00") if p]
    return [repo_root / p.decode("utf-8") for p in paths]


def _is_merge_conflict_marker_line(line: str) -> bool:
    # Match Git's exact conflict marker forms to avoid false positives from
    # common separator lines (e.g., pytest "=====" output in docs).
    s = line.rstrip()

    if s == "=======":
        return True

    if s == "<<<<<<<" or s.startswith("<<<<<<< "):
        return True

    if s == ">>>>>>>" or s.startswith(">>>>>>> "):
        return True

    if s == "|||||||" or s.startswith("||||||| "):
        return True

    return False


def test_no_merge_conflict_markers_in_tracked_files() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    files = _git_tracked_files(repo_root)

    offenders: list[str] = []

    for file_path in files:
        # Only scan regular files; skip submodules/etc.
        if not file_path.is_file():
            continue

        # Avoid pathological memory use on large artifacts.
        try:
            if file_path.stat().st_size > 2 * 1024 * 1024:
                continue
        except OSError:
            continue

        try:
            text = file_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue

        for line_number, line in enumerate(text.splitlines(), start=1):
            if _is_merge_conflict_marker_line(line):
                rel = file_path.relative_to(repo_root)
                offenders.append(f"{rel}:{line_number}: {line}")

    assert not offenders, "Merge conflict markers found:\n" + "\n".join(offenders[:50])
