from __future__ import annotations

import hashlib
import os
import socket
import urllib.error
import urllib.request
from enum import Enum
from typing import Dict, Optional, Tuple

from runtime.telemetry.phase_b_monitor import detect_decision_signature_violations


# Pinned expected SHA256 for PHASE_A_CERTIFICATION_VERDICT.md (operator should update)
EXPECTED_CERT_HASH: str = ""  # set to hex sha256 string to enable authenticity check

# Supported minimum versions (major, minor, patch)
MIN_KUBERNETES_VERSION: Tuple[int, int, int] = (1, 26, 0)
MIN_SPIRE_VERSION: Tuple[int, int, int] = (1, 3, 0)


class StartupState(Enum):
    ACTIVE = "ACTIVE"
    ACTIVE_WITH_WARNING = "ACTIVE_WITH_WARNING"
    DEGRADED = "DEGRADED"
    FAIL_FAST = "FAIL_FAST"


class PhaseBMonitorError(Exception):
    pass


class PhaseBMonitor:
    def __init__(self, metrics_url: str, timeout: float = 2.0):
        self.metrics_url = metrics_url
        # enforce explicit max timeout for Prometheus robustness
        self.timeout = min(float(timeout), 3.0)

    def fetch_metrics(self) -> str:
        """Fetch the Prometheus metrics text from the configured endpoint.

        - Uses standard library only (urllib.request)
        - Enforces timeout (clamped to 3s)
        - Validates HTTP 200
        - Raises PhaseBMonitorError on failure (no retries)
        """
        try:
            with urllib.request.urlopen(self.metrics_url, timeout=self.timeout) as resp:
                status = getattr(resp, "getcode", lambda: None)()
                if status is not None and int(status) != 200:
                    raise PhaseBMonitorError(f"unexpected http status: {status}")
                raw = resp.read()
                body = raw.decode("utf-8", "replace")
                # Basic content validation: required metric name must exist
                if "decision_signature_verification_failures_total" not in body:
                    raise PhaseBMonitorError("required metric not found in body")
                return body
        except (urllib.error.URLError, urllib.error.HTTPError, socket.timeout) as e:
            raise PhaseBMonitorError(f"failed to fetch metrics: {e}") from e

    def check_signature_failures(self, threshold: int = 0) -> Dict[str, object]:
        """Return advisory signal for decision signature verification failures.

        Returns a dict with keys: failure_count (int), threshold (int), violation (bool).
        Pure advisory — no writes, no side effects, no global state mutation.
        """
        metrics_text = self.fetch_metrics()
        count = detect_decision_signature_violations(metrics_text)
        return {"failure_count": int(count), "threshold": int(threshold), "violation": int(count) > int(threshold)}

    def _compute_file_sha256(self, path: str) -> Optional[str]:
        try:
            with open(path, "rb") as f:
                h = hashlib.sha256()
                while True:
                    chunk = f.read(8192)
                    if not chunk:
                        break
                    h.update(chunk)
                return h.hexdigest()
        except Exception:
            return None

    def _parse_version(self, v: Optional[str]) -> Optional[Tuple[int, ...]]:
        if not v:
            return None
        try:
            parts = [int(x) for x in v.strip().split(".") if x and x[0].isdigit()]
            return tuple(parts)
        except Exception:
            return None

    def _version_is_supported(self, ver: Optional[Tuple[int, ...]], minimum: Tuple[int, int, int]) -> Optional[bool]:
        if ver is None:
            return None
        v = tuple(list(ver) + [0] * (3 - len(ver)))[:3]
        return v >= minimum

    def verify_startup_invariants(self) -> Dict[str, object]:
        """Verify deterministic startup invariants for Phase B (read-only checks).

        Extended checks include artifact authenticity (sha256), HTTP/metrics validation,
        detector sanity, and lightweight version detection.
        """
        details: dict = {}

        # 1) Certification artifact presence (file presence only)
        cert_path = "PHASE_A_CERTIFICATION_VERDICT.md"
        cert_present = os.path.exists(cert_path)
        details["certification_present"] = bool(cert_present)

        # Artifact authenticity check (if EXPECTED_CERT_HASH set)
        details["cert_hash_checked"] = False
        details["cert_hash_matches"] = None
        if bool(EXPECTED_CERT_HASH) and cert_present:
            actual = self._compute_file_sha256(cert_path)
            details["cert_hash_checked"] = True
            details["cert_actual_hash"] = actual
            details["cert_expected_hash"] = EXPECTED_CERT_HASH
            details["cert_hash_matches"] = actual == EXPECTED_CERT_HASH

        # 2) Metrics endpoint reachable + detector callable + deterministic failure classification
        metrics_reachable = False
        detector_ok = False
        detector_value = None
        detector_error = None

        details["metrics_http_status"] = None
        details["metrics_body_contains_required"] = False
        details["metrics_failure_reason"] = None

        try:
            metrics_text = self.fetch_metrics()
            metrics_reachable = True
            details["metrics_body_contains_required"] = "decision_signature_verification_failures_total" in metrics_text
            try:
                detector_value = detect_decision_signature_violations(metrics_text)
                detector_ok = isinstance(detector_value, int)
            except Exception as de:
                detector_error = str(de)
                detector_ok = False
        except PhaseBMonitorError as e:
            msg = str(e)
            # timeout
            if "timed out" in msg or "timeout" in msg:
                details["metrics_failure_reason"] = "timeout"
            else:
                # attempt to detect HTTP status codes or HTTPError
                import re

                http_match = re.search(r"(HTTP Error\s*)?(\d{3})", msg, re.IGNORECASE)
                if http_match:
                    details["metrics_http_status"] = int(http_match.group(2))
                    details["metrics_failure_reason"] = "http_status"
                elif "required metric not found" in msg:
                    details["metrics_failure_reason"] = "missing_metric"
                else:
                    details["metrics_failure_reason"] = "other"
            details["metrics_reachable"] = False
            details["metrics_error"] = msg

        details["metrics_reachable"] = bool(metrics_reachable)
        details["detector_callable"] = detector_error is None
        details["detector_return_is_int"] = bool(detector_ok)
        details["detector_value"] = detector_value if detector_ok else None
        if detector_error:
            details["detector_error"] = detector_error

        # 3) Kubernetes API reachability: prefer env var, fallback to DNS resolution
        kube_ok = False
        try:
            if os.environ.get("KUBERNETES_SERVICE_HOST"):
                kube_ok = True
            else:
                socket.gethostbyname("kubernetes.default.svc")
                kube_ok = True
        except Exception:
            kube_ok = False
        details["kubernetes_api_reachable"] = kube_ok

        # 4) Version detection (env-var based, conservative)
        kver_str = os.environ.get("KUBERNETES_VERSION")
        spire_str = os.environ.get("SPIRE_VERSION")
        details["kubernetes_version"] = kver_str
        details["spire_version"] = spire_str
        kver = self._parse_version(kver_str)
        sver = self._parse_version(spire_str)
        details["kubernetes_supported"] = self._version_is_supported(kver, MIN_KUBERNETES_VERSION)
        details["spire_supported"] = self._version_is_supported(sver, MIN_SPIRE_VERSION)

        # readiness decision
        cert_ok = True
        if details.get("cert_hash_checked"):
            cert_ok = bool(details.get("cert_hash_matches"))

        ready = all(
            [
                details["certification_present"],
                cert_ok,
                details.get("metrics_reachable", False),
                details.get("detector_return_is_int", False),
                details.get("kubernetes_api_reachable", False),
            ]
        )

        return {"ready": bool(ready), "details": details}

    def start(self) -> StartupState:
        """Start Phase B monitor in a gated, non-invasive mode.

        - Verifies startup invariants; does NOT exit on failures.
        - Prints a structured advisory when invariants fail or warn.
        - Returns a `StartupState` enum value.
        """
        invariants = self.verify_startup_invariants()
        _raw_details = invariants.get("details", {})
        details: dict[str, object] = _raw_details if isinstance(_raw_details, dict) else {}

        if not invariants.get("ready"):
            # Structured, auditable DEGRADED advisory (no logging framework)
            print({"status": StartupState.DEGRADED.name, "details": details})
            return StartupState.DEGRADED

        # If versions are present but unsupported, return ACTIVE_WITH_WARNING
        kubernetes_supported = details.get("kubernetes_supported")
        spire_supported = details.get("spire_supported")
        if kubernetes_supported is False or spire_supported is False:
            print({"status": StartupState.ACTIVE_WITH_WARNING.name, "details": details})
            return StartupState.ACTIVE_WITH_WARNING

        return StartupState.ACTIVE
