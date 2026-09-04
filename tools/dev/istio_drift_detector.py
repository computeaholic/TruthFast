# tools/istio_drift_detector.py
import hashlib
import os
import subprocess

APPLY_DIR = "deploy/kube/istio-apply"


def sha256(s):
    return hashlib.sha256(s.encode()).hexdigest()


def slurp(path):
    with open(path) as f:
        return f.read()


def kubectl(path):
    return subprocess.check_output(["kubectl", "get", "-f", path, "-o", "yaml"], stderr=subprocess.STDOUT).decode()


print("THREADFORGE — ISTIO DRIFT REPORT")
print("----------------------------------")

for root, _, files in os.walk(APPLY_DIR):
    for f in files:
        if not f.endswith(".yaml"):
            continue
        p = os.path.join(root, f)

        local = slurp(p)
        try:
            live = kubectl(p)
        except subprocess.CalledProcessError:
            print(f"[MISSING] {p} → not found in cluster")
            continue

        if sha256(local) != sha256(live):
            print(f"[DRIFT] {p}")
        else:
            print(f"[OK] {p}")
