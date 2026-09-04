import httpx
from fastapi import FastAPI
from pgvector_client import PgVectorClient
from qdrant_client import QdrantClient

app = FastAPI()

qdrant = QdrantClient()
pgvec = PgVectorClient()

OPERATOR_AI_URL = "http://ella-core.ella-core.svc.cluster.local:8090"


async def ask_operator(event: dict) -> dict:
    async with httpx.AsyncClient() as client:
        r = await client.post(f"{OPERATOR_AI_URL}/deploy-event", json=event)
        return r.json()


@app.post("/route")
async def route_vector(request: dict):
    """The Operator-AI-driven vector arbitration endpoint."""
    event = {
        "service_name": "vector-router",
        "dimension": request["dimension"],
        "load": request["load"],
        "request_type": request["type"],
    }

    operator = await ask_operator(event)

    if operator["route"] == "gpu":
        return await qdrant.search(request)
    return pgvec.search(request)
