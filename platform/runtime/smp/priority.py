# runtime/smp/priority.py


def normalize_priority(payload: dict) -> int:
    p = payload.get("priority", 3)
    try:
        p = int(p)
    except Exception as err:
        raise ValueError("Priority must be an integer") from err

    if p < 1 or p > 5:
        raise ValueError(f"Priority {p} out of bounds (1–5)")

    return p
