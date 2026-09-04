# =====================================================================
# Vector API
# Path: api/routes/vector.py
# =====================================================================

from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel

from api.deps import VECTOR_EXECUTOR

router = APIRouter()


class VectorRequest(BaseModel):
    op: str
    payload: dict[str, Any]


@router.post("/execute")
def vector_execute(req: VectorRequest):
    return VECTOR_EXECUTOR.execute(req)
