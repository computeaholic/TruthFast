# api/

Purpose: compatibility package for legacy imports plus shared API configuration.

This directory is **not** an independent ThreadForge runtime API authority.
The canonical secondary FastAPI application is:

- application: `runtime.api.app:app`
- source: `platform/runtime/api/`
- image: `platform/images/api/Dockerfile`
- deployment: `platform/deploy/services/api/`

`api.app:app` exists only as a compatibility alias to `runtime.api.app:app`.
It must not define its own FastAPI application, routers, identity extraction, or
runtime authorization policy. There is no supported `api/Containerfile`.

Legacy route/helper modules may remain while older unit tests and non-runtime
callers are retired, but they do not constitute deployment evidence or a
supported public runtime API. Identity compatibility helpers must delegate to
the canonical proxy-bound XFCC contract and must never trust caller-asserted
SPIFFE headers.

What belongs here:

- shared API configuration still imported by canonical runtime code
- compatibility imports needed by retained tests or non-runtime callers

What does not belong here:

- an independent FastAPI application
- an independently buildable/deployable API image
- caller-controlled identity projection
- proof artifacts
- historical evidence
- deployment manifests
- generic platform bootstrap logic

Owner: Runtime API compatibility

Validation entry points:

- `pytest tests/runtime/test_runtime_authority_contract.py`
- `pytest tests/unit/identity/test_identity_enforcement.py`
- `make validate-all`

Related architecture:

- `docs/architecture/16-Repository-Information-Model.md`
- `docs/architecture/00-ThreadForge-Assurance-Reference-Architecture.md`
