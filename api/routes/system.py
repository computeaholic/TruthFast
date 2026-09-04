# =====================================================================
# System API
# Path: api/routes/system.py
# =====================================================================

import os
import time

from fastapi import APIRouter

router = APIRouter()


@router.get("/health")
def health():
    return {"status": "ok", "time": time.time()}


@router.get("/version")
def version():
    return {"version": "1.0.0", "git": os.environ.get("GIT_COMMIT", "unknown")}
