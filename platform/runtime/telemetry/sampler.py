from opentelemetry.sdk.trace.sampling import Decision

from .lineage import LineageContext


class ThreadForgeTailSampler:
    def should_sample(self, name: str, attributes: dict, ctx: LineageContext):
        # Keep capsule sealing and reflex gate unconditionally
        if name in ("capsule_seal", "reflex_gate"):
            return Decision.RECORD_AND_SAMPLE

        # Keep storage writes
        if name.startswith("storage."):
            return Decision.RECORD_AND_SAMPLE

        # Drift events ≥ 0.5 always sampled
        drift = attributes.get("drift.score")
        if drift is not None and float(drift) >= 0.5:
            return Decision.RECORD_AND_SAMPLE

        # Slow traces → keep (threshold 250ms)
        duration = attributes.get("slo.duration_ms")
        if duration and float(duration) >= 250:
            return Decision.RECORD_AND_SAMPLE

        # Default: keep 20%
        import random  # nosec B311: Non-cryptographic; used for trace sampling

        return (
            Decision.RECORD_AND_SAMPLE if random.random() < 0.20 else Decision.DROP
        )  # nosec B311: Non-cryptographic sampling
