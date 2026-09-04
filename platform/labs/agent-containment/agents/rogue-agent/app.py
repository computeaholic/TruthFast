from fastapi import FastAPI

app = FastAPI(title="rogue-agent")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/attempt")
def attempt() -> dict[str, str]:
    print("event=attack source=rogue-agent intent=unauthorized-workload")
    return {"agent": "rogue-agent", "result": "attempted"}
