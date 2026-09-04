from fastapi import FastAPI

app = FastAPI(title="attacker-agent")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/attack")
def attack() -> dict[str, str]:
    print("event=attack source=attacker-agent intent=lateral-or-exfiltration")
    return {"agent": "attacker-agent", "result": "attempted"}
