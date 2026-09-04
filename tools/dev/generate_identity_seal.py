import hashlib
from pathlib import Path

FILES = [
    "deploy/infra/spire/templates/registration-entries.yaml",
    "deploy/infra/spire/values.yaml",
    "deploy/controllers/sovereign-governor/lattice/tiers.yaml",
    "deploy/controllers/sovereign-governor/lattice/roles.yaml",
    "deploy/controllers/mesh-autopilot/drift-sensors.yaml",
]


def sha(path):
    return hashlib.sha3_512(Path(path).read_bytes()).hexdigest()


def main():
    out = ["# ThreadForge Identity Seal v1", ""]
    for f in FILES:
        out.append(f"- {f}: `{sha(f)}`")
    Path("IDENTITY_SEAL.md").write_text("\n".join(out))
    print("✔ Identity Seal generated: IDENTITY_SEAL.md")


if __name__ == "__main__":
    main()
