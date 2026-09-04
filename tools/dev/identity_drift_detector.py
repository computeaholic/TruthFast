import subprocess
from pathlib import Path

import yaml

ENTRIES = Path("deploy/infra/spire/templates/registration-entries.yaml")
GIT_CHECK = "git diff --name-only deploy/infra/spire/templates/registration-entries.yaml"


def git_diff_clean():
    changed = subprocess.getoutput(GIT_CHECK).strip()
    return changed == ""


def fetch_runtime_entries():
    out = subprocess.getoutput("kubectl get registrationentries.spire.spiffe.io -A -o yaml")
    return yaml.safe_load(out)["items"]


def main():
    # 1. Git drift
    if not git_diff_clean():
        print("❌ Git drift detected in registration entries")
        exit(1)
    print("✔ Git tree clean")

    # 2. Runtime drift
    repo_entries = list(yaml.safe_load_all(ENTRIES.read_text()))
    runtime_entries = fetch_runtime_entries()

    repo_ids = {e["spec"]["spiffeId"] for e in repo_entries}
    runtime_ids = {e["spec"]["spiffeId"] for e in runtime_entries}

    missing = repo_ids - runtime_ids
    extra = runtime_ids - repo_ids

    if missing:
        print("❌ Missing runtime identities:", missing)
        exit(1)

    if extra:
        print("❌ Unexpected runtime identities:", extra)
        exit(1)

    print("✔ Runtime identities match repository")


if __name__ == "__main__":
    main()
