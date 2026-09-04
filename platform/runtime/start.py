#!/usr/bin/env python3
# ============================================================================
# ThreadForge — Operator-AI Compatibility Start Script
# Location: runtime/start.py
# ============================================================================
# STATUS: The supported API deployment imports the identity visibility helper
# from this module. Older standalone Kubernetes/systemd entrypoints also invoke
# main(), so this file is compatibility-only rather than dead or reference-only.
# The secondary application operator is threadforge-api (FastAPI), which calls
# bootstrap() on startup. It is not the native V1 system kernel.
#
# Do not deploy this as a separate pod/service. The keepalive loop below
# would create a long-running process with no work to do.
# ============================================================================

from __future__ import annotations

import os
import time

from runtime.ai.runtime import bootstrap
from runtime.telemetry.bootstrap import init_telemetry


def _assert_identity_visibility():
    # Detect SPIRE presence by checking agent socket and set authority state accordingly.
    socket_path = os.getenv("THREADFORGE_SPIRE_AGENT_SOCKET", "/run/spire/agent.sock")
    try:
        import stat

        from runtime.authority.state import AuthorityState, set_state
        from runtime.spire.workload import is_workload_api_responsive

        # Revalidation starts from the safe state so a failed refresh cannot
        # inherit authority from an earlier process-local identity.
        set_state(AuthorityState.UNCLAIMED, "identity validation pending")

        if os.path.exists(socket_path) and stat.S_ISSOCK(os.stat(socket_path).st_mode):
            # Perform a lightweight workload API responsiveness probe
            if is_workload_api_responsive(socket_path):
                # Attempt real SVID fetch & validation. Only on success do we mark AUTHORITATIVE.
                try:
                    # Use gRPC Workload API for authoritative SVID fetch
                    from runtime.authority.signing import load_authority_private_key
                    from runtime.spire.grpc_client import GRPCClientError, fetch_and_validate_svid_via_grpc

                    spiffe_id, identity_hash, expiry_dt = fetch_and_validate_svid_via_grpc(socket_path)

                    # Ensure signing key present before allowing authoritative transition
                    key = load_authority_private_key()
                    if key is None:
                        raise RuntimeError("Authority private key not available; cannot become AUTHORITATIVE")

                    # Persist validated identity material and become authoritative
                    from runtime.authority.state import set_validated_identity

                    set_validated_identity(spiffe_id, identity_hash, expiry_dt.isoformat())
                    set_state(AuthorityState.AUTHORITATIVE, f"Validated SVID {spiffe_id}")

                    try:
                        from runtime.telemetry.prometheus_exporter import (
                            set_authority_authoritative,
                            update_identity_coverage,
                        )

                        set_authority_authoritative(True)
                        update_identity_coverage(1.0)
                    except Exception:
                        pass
                except GRPCClientError as e:
                    # If failure is due to missing generated proto modules, this is a build integrity failure
                    if "generated proto modules" in str(e):
                        raise RuntimeError(f"Build integrity failure: {e}") from e
                    # Validation failed; remain UNCLAIMED (authority unclaimed)
                    set_state(
                        AuthorityState.UNCLAIMED,
                        f"SPIRE Workload API responsive but SVID validation failed: {e}",
                    )
                    try:
                        from runtime.telemetry.prometheus_exporter import (
                            set_authority_authoritative,
                            update_identity_coverage,
                        )

                        set_authority_authoritative(False)
                        update_identity_coverage(0.0)
                    except Exception:
                        pass
                except Exception as e:
                    set_state(
                        AuthorityState.UNCLAIMED,
                        f"SPIRE Workload API responsive but SVID validation failed: {e}",
                    )
                    try:
                        from runtime.telemetry.prometheus_exporter import (
                            set_authority_authoritative,
                            update_identity_coverage,
                        )

                        set_authority_authoritative(False)
                        update_identity_coverage(0.0)
                    except Exception:
                        pass
            else:
                set_state(
                    AuthorityState.UNCLAIMED,
                    f"SPIRE socket present but Workload API unresponsive at {socket_path}",
                )
                try:
                    from runtime.telemetry.prometheus_exporter import (
                        set_authority_authoritative,
                        update_identity_coverage,
                    )

                    set_authority_authoritative(False)
                    update_identity_coverage(0.0)
                except Exception:
                    pass
        else:
            set_state(
                AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY,
                f"SPIRE agent socket not found at {socket_path}",
            )
            try:
                from runtime.telemetry.prometheus_exporter import (
                    set_authority_authoritative,
                    update_identity_coverage,
                )

                set_authority_authoritative(False)
                update_identity_coverage(0.0)
            except Exception:
                pass
    except Exception as e:
        # If a RuntimeError (e.g., Build integrity failure) was raised intentionally, propagate it to fail-fast
        if isinstance(e, RuntimeError):
            raise
        print(f"[WARN] Identity visibility check failed: {e}")
        # Set non-authoritative as a safe default
        from runtime.authority.state import AuthorityState, set_state

        set_state(AuthorityState.UNCLAIMED, f"identity check error: {e}")

        try:
            from runtime.telemetry.prometheus_exporter import (
                set_authority_authoritative,
                update_identity_coverage,
            )

            set_authority_authoritative(False)
            update_identity_coverage(0.0)
        except Exception:
            pass


def main():
    print("[Operator-AI] Bootstrapping runtime…")
    # Initialize telemetry first (OTel -> Tempo -> Grafana)
    from runtime.lifecycle import Phase, set_phase

    try:
        init_telemetry()
        print("[Operator-AI] Telemetry initialized")
    except Exception:
        print("[Operator-AI] Telemetry initialization failed or OTel packages missing; continuing")

    # Mark boot phase explicitly (authority-neutral)
    set_phase(Phase.BOOT, reason="startup")

    bootstrap()
    _assert_identity_visibility()

    # Mark running phase
    set_phase(Phase.RUNNING, reason="runtime online")

    print("[Operator-AI] Runtime online.")
    print("[Operator-AI] Awaiting SMP messages…")

    # Graceful shutdown handler (authority-agnostic)
    import signal
    import sys

    from runtime.signal.fabric import emit as _emit

    def _shutdown(signum, frame):
        print("[Operator-AI] Shutdown requested (signal=%s)" % signum)
        set_phase(Phase.IDLE, reason=f"signal-{signum}")
        _emit("SHUTTING_DOWN", {"signal": signum, "when": time.time()})
        # Allow for graceful cleanup - flush logs, brief sleep
        time.sleep(0.25)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    # Deterministic idle loop (PHASE 0: CONTAINED)
    # ============================================================================
    # CONTAINMENT: No background daemons or hidden schedulers.
    #
    # All work is operator-initiated via SMP HTTP ingress (not autonomous).
    # The Operator-AI Brainstem is instantiated but INERT (not auto-started).
    #
    # Previous (UNSAFE) comment claimed "handled by background daemons" — this is
    # false and violated declared architecture. See:
    #   - /tmp/FORENSIC_AUTONOMOUS_EXECUTION_REPORT.md (Phase 0 analysis)
    #   - .github/copilot-instructions.md (Deterministic Bootstrapping)
    #
    # This ensures:
    #   ✓ Deterministic startup and shutdown semantics
    #   ✓ No autonomous execution without operator intent
    #   ✓ Identity-first, denial-first architecture compliance
    # ============================================================================
    while True:
        time.sleep(1.0)


if __name__ == "__main__":
    main()
