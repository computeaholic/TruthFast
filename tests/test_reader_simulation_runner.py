from __future__ import annotations

from tools.multi_pass_reader_simulation import run_multi_pass_reader_simulation


def test_failure_results_in_incomplete() -> None:
    def invoke_fail(_request: object) -> str:
        raise TimeoutError("simulated timeout")

    result = run_multi_pass_reader_simulation([{"pass_id": "p1"}], invoke_fail)

    assert result["status"] == "INCOMPLETE"
    assert len(result["failures"]) > 0


def test_empty_valid_results_in_clean() -> None:
    def invoke_empty(_request: object) -> str:
        return '{"findings": []}'

    result = run_multi_pass_reader_simulation([{"pass_id": "p1"}], invoke_empty)

    assert result["status"] == "CLEAN"
    assert result["findings"] == []
    assert result["failures"] == []


def test_findings_present_results_in_findings_present() -> None:
    def invoke_findings(_request: object) -> str:
        # Top-level list form must remain supported.
        return '[{"id": "f1", "severity": "high"}]'

    result = run_multi_pass_reader_simulation([{"pass_id": "p1"}], invoke_findings)

    assert result["status"] == "FINDINGS_PRESENT"
    assert len(result["findings"]) == 1
    assert result["failures"] == []
