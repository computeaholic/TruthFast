from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Callable, List, Optional


@dataclass
class Failure:
    type: str
    message: Optional[str] = None
    pass_id: Optional[str] = None


@dataclass
class ReaderResult:
    findings: List[dict]
    failures: List[Failure]


def _normalize_payload(payload: Any) -> dict:
    """Normalize payload to the canonical object schema.

    Supported forms:
    - top-level list: [{...}]
    - object form: {"findings": [...]}
    """
    if isinstance(payload, list):
        return {"findings": payload}

    if isinstance(payload, dict) and isinstance(payload.get("findings"), list):
        return payload

    raise ValueError("response must be a list or an object containing findings")


def _validate_findings(findings: Any) -> List[dict]:
    if not isinstance(findings, list):
        raise ValueError("findings must be a list")

    validated: List[dict] = []
    for finding in findings:
        if not isinstance(finding, dict):
            raise ValueError("each finding must be an object")
        validated.append(finding)

    return validated


def _run_single_pass(
    invoke_pass: Callable[..., Any],
    *invoke_args: Any,
    pass_id: Optional[str] = None,
    **invoke_kwargs: Any,
) -> ReaderResult:
    """Run a single pass invocation + parse/validation step."""
    try:
        raw_response = invoke_pass(*invoke_args, **invoke_kwargs)
    except TimeoutError as exc:
        return ReaderResult(
            findings=[],
            failures=[Failure(type="timeout", message=str(exc), pass_id=pass_id)],
        )
    except Exception as exc:  # noqa: BLE001
        return ReaderResult(
            findings=[],
            failures=[Failure(type="invocation_error", message=str(exc), pass_id=pass_id)],
        )

    if raw_response is None or (isinstance(raw_response, str) and not raw_response.strip()):
        return ReaderResult(
            findings=[],
            failures=[Failure(type="empty_response", pass_id=pass_id)],
        )

    try:
        payload = json.loads(raw_response) if isinstance(raw_response, str) else raw_response
    except json.JSONDecodeError as exc:
        return ReaderResult(
            findings=[],
            failures=[Failure(type="invalid_schema", message=str(exc), pass_id=pass_id)],
        )

    try:
        normalized = _normalize_payload(payload)
        validated_findings = _validate_findings(normalized["findings"])
    except ValueError as exc:
        return ReaderResult(
            findings=[],
            failures=[Failure(type="invalid_schema", message=str(exc), pass_id=pass_id)],
        )
    except Exception as exc:  # noqa: BLE001
        return ReaderResult(
            findings=[],
            failures=[Failure(type="execution_error", message=str(exc), pass_id=pass_id)],
        )

    return ReaderResult(findings=validated_findings, failures=[])


def run_pass_with_retry(
    invoke_pass: Callable[..., Any],
    *invoke_args: Any,
    pass_id: Optional[str] = None,
    **invoke_kwargs: Any,
) -> ReaderResult:
    """Deterministic bounded retry wrapper (max 2 attempts)."""
    last_result: Optional[ReaderResult] = None

    for _attempt in range(2):
        result = _run_single_pass(
            invoke_pass,
            *invoke_args,
            pass_id=pass_id,
            **invoke_kwargs,
        )

        if not result.failures:
            return result

        last_result = result

    return last_result or ReaderResult(
        findings=[],
        failures=[Failure(type="execution_error", message="no attempts executed", pass_id=pass_id)],
    )


def run_multi_pass_reader_simulation(
    pass_requests: List[Any],
    invoke_pass: Callable[[Any], Any],
) -> dict:
    """Run all pass requests and classify final result truthfully."""
    all_findings: List[dict] = []
    all_failures: List[Failure] = []

    for index, pass_request in enumerate(pass_requests):
        pass_id = str(getattr(pass_request, "pass_id", None) or index)
        result = run_pass_with_retry(invoke_pass, pass_request, pass_id=pass_id)
        all_findings.extend(result.findings)
        all_failures.extend(result.failures)

    if all_failures:
        final_status = "INCOMPLETE"
    elif not all_findings:
        final_status = "CLEAN"
    else:
        final_status = "FINDINGS_PRESENT"

    print("[READER]")
    print(f"Findings: {len(all_findings)}")
    print(f"Failures: {len(all_failures)}")
    print(f"Status: {final_status}")

    return {
        "findings": all_findings,
        "failures": [failure.__dict__ for failure in all_failures],
        "status": final_status,
    }


def run_reader_pass(invoke_pass: Callable[..., Any], *args: Any, **kwargs: Any) -> List[dict]:
    """Compatibility helper returning only findings for successful callers."""
    return run_pass_with_retry(invoke_pass, *args, **kwargs).findings
