# Canonical Audit Model

TruthFast maintains a tamper-evident, hash-chained audit record of
enforcement events. Cryptographic signatures anchor the genesis record and
signing-key registry; individual events are members of the hash chain rather
than independently cosign-signed records.

---

## Audit Log Structure

**Location**: `artifacts/audit/audit.log`
**Format**: JSONL — one event per line

Each entry contains:

- `event_type`: admission event classification (`allow`, `deny`, `breakglass`)
- `timestamp`: RFC3339 timestamp
- `prev_hash`: SHA-256 hash of the previous entry (genesis entry uses `"0" * 64`)
- `breakglass`: boolean — `true` if the event was a break-glass override
- Event-specific fields (workload identity, policy name, namespace, etc.)

---

## Hash Chain

The log is internally chained: every entry's SHA-256 digest (computed over canonical JSON) is the `prev_hash` of the next entry. The chain is validated end-to-end by `verify_audit_logging.sh`.

**Genesis anchor**: the first entry's hash is stored as `artifacts/audit/audit.chain.json` with a cosign-signed genesis signature (`artifacts/audit/audit.genesis.sig`). This binds the start of the chain to a key-based signature that cannot be reconstructed without the signing key.

**Key rotation continuity**: the audit signing key registry (`artifacts/audit/signing_key_registry.json`) records all signing key IDs used over the audit history. The registry itself is cosign-signed. Both `cosign_v1` and `cosign_v2` key IDs are present, confirming that rotation did not break chain continuity.

---

## Audit Guarantees

| Guarantee                       | Mechanism                                                                   |
| ------------------------------- | --------------------------------------------------------------------------- |
| All enforcement events recorded | Admission path writes to audit log before returning                         |
| Chain integrity verifiable      | SHA-256 prev_hash per entry; `verify_audit_logging.sh` traverses full chain |
| Genesis tamper detection        | Cosign-signed genesis hash; forgery requires signing key                    |
| Key rotation continuity         | `signing_key_registry.json` + registry signature                            |
| Break-glass events audited      | `breakglass: true` in entry; proof validates `breakglass_seen: true`        |
| Fail-closed writes              | Audit write failure propagates as proof failure                             |

---

## Break-Glass Audit Requirement

Every break-glass action (emergency admission of a normally-denied workload) must appear in the audit log with `"breakglass": true`. Proof verifies `breakglass_seen: true` in the audit validation artifact. A break-glass event that is not recorded is a CONTRACT_VIOLATION.

---

## Verification Scripts

- `scripts/verify/verify_audit_logging.sh` — full chain + genesis + signature validation
- `scripts/verify/verify_audit_key_rotation_continuity.sh` — key rotation record integrity

---

## Known Limitation

The audit log chain is tamper-evident from within the chain itself, and the genesis is cosign-signed. However, a party who controls the cluster filesystem AND holds the signing key can reconstruct a valid chain from scratch. Mitigation: the signing key is stored outside the cluster (in `~/.threadforge-signing/`). External anchoring (e.g., writing the final hash to an append-only external store) is a known non-claim — see [Agent-Containment.md](../Agent-Containment.md#threat-boundary-and-non-claims).

---

## Current Audit Contract

The canonical audit verifier is `scripts/verify/verify_audit_logging.sh`.
It validates the current artifact rather than relying on a fixed event count.
The contract includes:

- malformed JSON and non-object tail entries are rejected;
- every non-genesis entry must carry the expected `prev_hash`;
- the hash chain is validated before an append is accepted;
- `threadforge-breakglass` request metadata must be reflected by
  `breakglass: true` and is included in the hash-bound event;
- the signing-key registry, rotation edges, and cosign-signed genesis proof
  are validated together.

Individual events are hash-chain members; they are not represented as
independently cosign-signed records. The audit aggregate is an operator
diagnostic surface (`make audit`), while proof/certification checks consume
separate assurance artifacts.
