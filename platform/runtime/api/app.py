"""SECONDARY FASTAPI APPLICATION ENTRYPOINT

This FastAPI application is the authoritative ingress only for the optional
secondary application closure. It is not deployed by native V1 Golden Boot and
is not used by the four supported reviewer demos.

All requests:
HTTP → SMP Envelope → Reflex → Ledger → Backend

Other routers (e.g. router-go) are outside this secondary control path.
"""

import json
import logging
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import APIRouter, FastAPI, Request, Response

from runtime.ai.intent_registry import init_registry
from runtime.api.observability_api import router as observability_router
from runtime.api.operator_introspection import router as operator_router
from runtime.api.router_api import router as vector_router
from runtime.telemetry.prometheus_exporter import prometheus_metrics

# ================================================================
# Logging Configuration (Structured Logging)
# ================================================================
APP_LOG_PATH = "artifacts/logs/operator_api.jsonl"

logger = logging.getLogger("operator_api")
logger.setLevel(logging.INFO)
Path(APP_LOG_PATH).parent.mkdir(parents=True, exist_ok=True)
handler = logging.FileHandler(APP_LOG_PATH)
handler.setFormatter(logging.Formatter("%(message)s"))
logger.addHandler(handler)


def log_structured(event: dict):
    """Append a JSONL event to audit logs."""
    with open(APP_LOG_PATH, "a") as f:
        f.write(json.dumps(event) + "\n")


# ================================================================
# Lifespan — Initialize Runtime & Intent Registry
# ================================================================
# SECONDARY APPLICATION OPERATOR INITIALIZATION
# This is the only place where OperatorCore is activated in the FastAPI closure.
# bootstrap() initializes operator_core, which processes all SMP envelopes.
# No separate operator-ai deployment, no background threads, no polling.
# ================================================================
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize operator runtime and intent registry on startup.

    This FastAPI application is the secondary application operator.
    All events arrive via HTTP → SMP envelope → operator_core.execute().
    """
    # Initialize OpenTelemetry tracing first (before any instrumented code runs)
    from runtime.telemetry.bootstrap import init_telemetry

    try:
        init_telemetry()
        log_structured({"ts": time.time(), "event": "startup_complete", "component": "telemetry"})
    except Exception as e:
        log_structured({"ts": time.time(), "event": "startup_warning", "component": "telemetry", "error": str(e)})
        # Don't raise - allow startup to continue without telemetry

    # Initialize SPIRE identity visibility (sets authority state)
    from runtime.start import _assert_identity_visibility

    try:
        _assert_identity_visibility()
        log_structured({"ts": time.time(), "event": "startup_complete", "component": "spire_identity"})
    except Exception as e:
        log_structured({"ts": time.time(), "event": "startup_warning", "component": "spire_identity", "error": str(e)})
        # Don't raise - allow startup to continue without SPIRE identity

    # Initialize operator core (bootstrap)
    # This call is idempotent (safe to call multiple times)
    from runtime.ai.runtime import bootstrap

    try:
        bootstrap()
        log_structured({"ts": time.time(), "event": "startup_complete", "component": "operator_runtime"})
    except Exception as e:
        log_structured({"ts": time.time(), "event": "startup_error", "component": "operator_runtime", "error": str(e)})
        raise

    # Initialize intent registry from ConfigMap
    try:
        init_registry()
        log_structured({"ts": time.time(), "event": "startup_complete", "component": "intent_registry"})
    except Exception as e:
        log_structured({"ts": time.time(), "event": "startup_error", "component": "intent_registry", "error": str(e)})
        raise

    yield


# ================================================================
# FastAPI App
# ================================================================
app = FastAPI(
    title="ThreadForge Operator-AI Gateway",
    description="SMP-secured API interface for all vector operations.",
    version="1.0.0",
    lifespan=lifespan,
)


# ================================================================
# CORS Middleware (P1.4: Fixed)
# ================================================================
# Per Finding #12 (CORS Wildcard + Credentials):
# Removed wildcard origins. No allow_credentials with unrestricted origins.
# If CORS is needed, restrict to explicit trusted origins.
# For now, CORS is disabled per security-first principle.
# Enable with explicit origins if required by deployment.
#
# app.add_middleware(
#     CORSMiddleware,
#     allow_origins=["https://trusted-domain.example.com"],  # Explicit origins only
#     allow_credentials=False,  # Or True only with restricted origins
#     allow_methods=["POST"],
#     allow_headers=["Content-Type", "x-spiffe-id", "x-forwarded-client-cert"],
# )


# ================================================================
# Middleware — Full Lifecycle Logging
# ================================================================
@app.middleware("http")
async def logging_middleware(request: Request, call_next):
    """Structured logging:
    - Per-request trace ID
    - Input metadata capture
    - Post-response outcome logging
    - Reflex + Operator-AI annotation support
    """
    trace_id = str(uuid.uuid4())
    start_time = time.time()

    request_body = await request.body()
    try:
        body_json = json.loads(request_body.decode("utf-8") or "{}")
    except Exception:
        body_json = {}

    # ------------------------------------------------------------
    # Log request
    # ------------------------------------------------------------
    log_structured(
        {
            "ts": start_time,
            "event": "request_start",
            "trace_id": trace_id,
            "method": request.method,
            "path": request.url.path,
            "payload": body_json,
        },
    )

    # ------------------------------------------------------------
    # Execute underlying route
    # ------------------------------------------------------------
    try:
        response: Response = await call_next(request)
        status = "success"
    except Exception as exc:
        status = "error"
        response = Response(
            json.dumps({"error": str(exc), "trace_id": trace_id}),
            status_code=500,
            media_type="application/json",
        )

    # ------------------------------------------------------------
    # Log response
    # ------------------------------------------------------------
    end_time = time.time()
    duration = end_time - start_time

    log_structured(
        {
            "ts": end_time,
            "event": "request_end",
            "trace_id": trace_id,
            "duration_ms": duration * 1000,
            "status": status,
        },
    )

    # Attach trace ID to response
    response.headers["X-Trace-ID"] = trace_id

    return response


# ================================================================
# DEPRECATED: Unauthenticated Health Endpoints (Removed in P1)
# ================================================================
# The /, /healthz, and /diagnostics endpoints have been removed
# per Finding #2 (Unauthenticated Health Check Endpoints).
#
# Health checks must be enforced at Istio layer via mTLS,
# not at the application layer with unprotected endpoints.
#
# Kubernetes probes should use mTLS client certificates.
# See AFRL_REMEDIATION_TECHNICAL_GUIDE.md for probe configuration.


# ================================================================
# Mount Operator Vector API
# ================================================================
app.include_router(vector_router, prefix="/vector")

# ================================================================
# Mount Operator Introspection API
# ================================================================
app.include_router(operator_router)

# ================================================================
# Mount ObservationPlane API (CCID-scoped read-only)
# ================================================================
app.include_router(observability_router)

# ================================================================
# Mount Metrics API
# ================================================================
metrics_router = APIRouter()


@metrics_router.get("/metrics")
def metrics():
    data, content_type = prometheus_metrics()
    return Response(content=data, media_type=content_type)


app.include_router(metrics_router)


# ================================================================
# Envelope Injector
# (Optional advanced hook you can enable later)
# ================================================================
# Removed: Speculative middleware creates reviewer bait
