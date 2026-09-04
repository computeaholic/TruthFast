#!/usr/bin/env python3
"""
detect-image-drift.sh

Prototype drift detector (read-only by design). Does not call kubectl unless explicitly configured via environment.
- Parses git-pinned digests from platform/deploy/** manifests
- Inspects registry digests (mockable or via skopeo)
- Compares against live cluster imageIDs via a stub (mockable)
- Outputs structured JSON matching the enforcement design

Usage: ./scripts/detect-image-drift.sh --mode observe --output-json out/drift-report.json

Environment variables for testing/mocking:
- MOCK_REGISTRY=1 and file mocks/registry.json will be used as registry responses
- MOCK_LIVE=1 and file mocks/live.json will be used as live cluster responses
"""
import argparse
import json
import os
import re
import subprocess
from datetime import datetime, timezone


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('--mode', choices=['observe','warn','enforce'], default='observe')
    p.add_argument('--output-json', required=True)
    return p.parse_args()


def gather_git_pins():
    pins = {}
    for root, _, files in os.walk('deploy'):
        for fn in files:
            path = os.path.join(root, fn)
            try:
                with open(path, 'r', encoding='utf-8') as fh:
                    for ln in fh:
                        m = re.search(r'(?P<image>[^\s]+)@(?P<digest>sha256:[0-9a-f]{64})', ln)
                        if m:
                            image = m.group('image')
                            digest = m.group('digest')
                            pins[image] = digest
            except Exception:
                continue
    return pins


def registry_inspect(image_with_digest):
    # image_with_digest looks like 'registry.../repo@sha256:...'
    if os.environ.get('MOCK_REGISTRY'):
        try:
            with open('mocks/registry.json','r',encoding='utf-8') as fh:
                data = json.load(fh)
                return data.get(image_with_digest)
        except Exception:
            return None
    # Try skopeo if available
    try:
        out = subprocess.check_output(['skopeo','inspect','--raw', f'docker://{image_with_digest}'], text=True)
        # crude: return the manifest raw string (caller can compute digest if needed)
        return True
    except Exception:
        return None


def live_cluster_images():
    if os.environ.get('MOCK_LIVE'):
        try:
            with open('mocks/live.json','r',encoding='utf-8') as fh:
                return json.load(fh)
        except Exception:
            return {}
    # Stub: no live cluster access in prototype
    return {}


def main():
    args = parse_args()
    mode = args.mode
    out = args.output_json

    pins = gather_git_pins()

    registry_results = {}
    for image, digest in pins.items():
        key = f"{image}@{digest}"
        registry_ok = registry_inspect(key)
        registry_results[image] = {
            'git_digest': digest,
            'registry_present': bool(registry_ok),
            'registry_raw': registry_ok if not isinstance(registry_ok, bool) else None
        }

    live = live_cluster_images()

    results = []
    for image, info in registry_results.items():
        live_digest = live.get(image)
        status = 'ok'
        action = 'none'
        if not info['registry_present']:
            status = 'registry_mismatch'
            action = 'issue'
        elif live_digest and live_digest != info['git_digest']:
            status = 'live_mismatch'
            action = 'issue'
        results.append({
            'image': image,
            'git_digest': info['git_digest'],
            'registry_present': info['registry_present'],
            'live_digest': live_digest,
            'status': status,
            'action': action
        })

    report = {
        'mode': mode,
        'generated_at': datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        'results': results
    }
    # Ensure directory exists (handle bare filenames safely)
    dirpath = os.path.dirname(out) or '.'
    os.makedirs(dirpath, exist_ok=True)
    with open(out, 'w', encoding='utf-8') as fh:
        json.dump(report, fh, indent=2)
    # human summary
    print(f"Drift detection completed: {len(results)} images analyzed")
    for r in results:
        print(f"- {r['image']}: status={r['status']} action={r['action']}")
    # Exit code non-zero only in enforce mode with actionable drift
    if mode == 'enforce' and any(r['action']=='issue' for r in results):
        raise SystemExit(2)

if __name__ == '__main__':
    main()
