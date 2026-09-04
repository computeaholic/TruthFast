from fastapi import FastAPI

app = FastAPI(title="writer-agent")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/write")
def write() -> dict[str, str]:
    print("event=write source=research-agent destination=writer-agent status=accepted")
    return {"agent": "writer-agent", "result": "written"}
