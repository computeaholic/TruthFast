from fastapi import FastAPI

app = FastAPI(title="research-agent")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/research")
def research() -> dict[str, str]:
    print("event=allow source=research-agent destination=writer-agent action=research")
    return {"agent": "research-agent", "result": "ok"}
