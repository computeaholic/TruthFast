#!/usr/bin/env python3
"""
check-build-tooling.sh

Prototype linter for banned build invocations.
- Scans file list (or git diff) for banned patterns
- Supports an allowlist file: .github/BUILD_EXCEPTIONS (simple CSV lines or YAML if PyYAML available)
- Supports inline pragmas: '# BUILD-ALLOW: ...'
- Modes: observe|warn|enforce
- Outputs: JSON (machine-readable) and human summary to stdout

Usage:
  ./scripts/check-build-tooling.sh --mode observe --output-json out/report.json [--files file1,file2,...]

Note: this is a prototype requiring no external libraries (PyYAML optional). Designed to be auditable.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

# Regex rules (PCRE-like)
RULES = {
    "docker_build": {
        "regex": re.compile(r"(?i)\bdocker\s+build\b"),
        "description": "Use of 'docker build' (local daemon builds) is banned for production images",
    },
    "docker_buildx_no_builder": {
        "regex": re.compile(r"(?i)docker\s+buildx\s+build(?:(?!--builder\s+threadforge-builder).)*$", re.MULTILINE),
        "description": "'docker buildx build' must target the canonical builder '--builder threadforge-builder' or use the buildkit client wrapper",
    },
    "kaniko_invocation": {
        "regex": re.compile(r"(?i)\bkaniko\b|\bgcr\.io/kaniko-project/executor\b|\bexecutor:.*kaniko\b"),
        "description": "Kaniko usage detected; allowed only as KANIKO_FALLBACK with justification",
    },
    "ctr_import": {
        "regex": re.compile(r"(?i)\bctr\b(?:\s+-n\s+k8s\.io)?\s+images\s+import\b"),
        "description": "'ctr images import' is allowed only for bootstrap/repair workflows",
    },
}

ALLOWLIST_PATH = ".github/BUILD_EXCEPTIONS"
KANIKO_ALLOWLIST = ".github/KANIKO_ALLOWLIST"
BOOTSTRAP_ALLOWLIST = ".github/BOOTSTRAP_ALLOWLIST"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--mode", choices=["observe", "warn", "enforce"], default="observe")
    p.add_argument("--files", help="Comma-separated list of files to scan (default: all tracked files)")
    p.add_argument("--output-json", help="Path to write JSON output", required=True)
    return p.parse_args()


def get_tracked_files():
    try:
        out = subprocess.check_output(["git", "ls-files"], text=True)
        return [l.strip() for l in out.splitlines() if l.strip()]
    except Exception:
        # Fallback: walk repo
        files = []
        for root, _, filenames in os.walk("."):
            for f in filenames:
                files.append(os.path.join(root, f))
        return files


def load_simple_allowlist(path):
    allow = []
    if not os.path.exists(path):
        return allow
    with open(path, "r", encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            # Support simple pipe-separated: path|rule|reason|expires|approver
            parts = ln.split("|")
            if len(parts) < 2:
                continue
            entry = {
                "path": parts[0].strip(),
                "rule": parts[1].strip() if len(parts) >= 2 else "",
                "reason": parts[2].strip() if len(parts) >= 3 else "",
                "expires": parts[3].strip() if len(parts) >= 4 else None,
                "approver": parts[4].strip() if len(parts) >= 5 else None,
            }
            allow.append(entry)
    return allow


def inline_pragma_allows(line):
    # Example: # BUILD-ALLOW: docker-build reason="temporary" expires=2026-03-01 approver=alice
    m = re.search(r"BUILD-ALLOW:\s*(.+)$", line)
    if not m:
        return None
    payload = m.group(1)
    parts = {}
    # crude parsing: key=val pairs and a first token for rule
    tokens = re.split(r"\s+", payload)
    if tokens:
        parts['rule'] = tokens[0]
    for t in tokens[1:]:
        kv = t.split("=", 1)
        if len(kv) == 2:
            k, v = kv
            parts[k] = v.strip('"')
    return parts


def check_file(path, rules, allowlists):
    findings = []
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            lines = fh.readlines()
    except Exception:
        return findings
    for idx, ln in enumerate(lines, start=1):
        for rule_name, rule in rules.items():
            if rule['regex'].search(ln):
                # Check if in docs/markdown or md files -> allowed (docs allowed)
                if path.endswith('.md') or path.startswith('docs/') or path.endswith('.rst'):
                    continue
                # Check for inline pragma on this or nearby line
                allow = None
                # check same line
                ip = inline_pragma_allows(ln)
                if ip and ip.get('rule') and ip.get('rule').lower() in rule_name.replace('_', '-'):
                    allow = {'inline': ip}
                # or previous 2 lines
                if not allow:
                    for k in range(max(0, idx-3), min(len(lines), idx+2)):
                        ip2 = inline_pragma_allows(lines[k])
                        if ip2 and ip2.get('rule') and ip2.get('rule').lower() in rule_name.replace('_', '-'):
                            allow = {'inline': ip2}
                            break
                # Check allowlist entries matching path and rule
                path_allows = [e for e in allowlists if e['path'] in path and (e['rule'] == rule_name or e['rule'] == 'any')]
                if path_allows:
                    allow = {'allowlist': path_allows}
                findings.append({
                    'file': path,
                    'line': idx,
                    'snippet': ln.strip(),
                    'rule': rule_name,
                    'description': rule['description'],
                    'allow': allow is not None,
                    'allow_detail': allow,
                })
    return findings


def expiry_ok(expires_str):
    if not expires_str:
        return False
    try:
        exp = datetime.strptime(expires_str, "%Y-%m-%d").date()
        return exp >= datetime.now(timezone.utc).date()
    except Exception:
        return False


def main():
    args = parse_args()
    mode = args.mode
    files = []
    if args.files:
        files = args.files.split(',')
    else:
        files = get_tracked_files()
    allowlist = load_simple_allowlist(ALLOWLIST_PATH)
    # also load kaniko and bootstrap lists (same simple format)
    kaniko_allow = load_simple_allowlist(KANIKO_ALLOWLIST) if os.path.exists(KANIKO_ALLOWLIST) else []
    bootstrap_allow = load_simple_allowlist(BOOTSTRAP_ALLOWLIST) if os.path.exists(BOOTSTRAP_ALLOWLIST) else []
    findings = []
    for f in files:
        findings.extend(check_file(f, RULES, allowlist + kaniko_allow + bootstrap_allow))
    # Post-process allow expiry logic
    for fd in findings:
        allow = fd['allow_detail']
        fd['allow_expired'] = False
        if allow and 'allowlist' in allow:
            for e in allow['allowlist']:
                if e.get('expires') and not expiry_ok(e['expires']):
                    fd['allow_expired'] = True
        if allow and 'inline' in allow:
            if allow['inline'].get('expires') and not expiry_ok(allow['inline'].get('expires')):
                fd['allow_expired'] = True
    # Determine status
    issues = []
    for fd in findings:
        blocked = (not fd['allow']) or (fd['allow'] and fd.get('allow_expired'))
        sever = 'warn' if mode in ['observe','warn'] else 'fail'
        level = 'warn' if (mode != 'enforce' and blocked) else ('fail' if blocked else 'ok')
        issues.append({
            'file': fd['file'], 'line': fd['line'], 'rule': fd['rule'], 'snippet': fd['snippet'],
            'description': fd['description'], 'allow': fd['allow'], 'allow_expired': fd.get('allow_expired', False), 'status': level
        })
    report = {
        'mode': mode,
        'generated_at': datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        'findings': issues,
        'summary': {
            'total_findings': len(issues),
            'failures': sum(1 for i in issues if i['status']=='fail'),
            'warnings': sum(1 for i in issues if i['status']=='warn')
        }
    }
    out = args.output_json
    # Ensure directory exists (handle bare filenames safely)
    dirpath = os.path.dirname(out) or '.'
    os.makedirs(dirpath, exist_ok=True)
    with open(out, 'w', encoding='utf-8') as fh:
        json.dump(report, fh, indent=2)
    # Human summary
    print(f"Mode: {mode}")
    print(f"Total findings: {report['summary']['total_findings']} (warnings: {report['summary']['warnings']}, failures: {report['summary']['failures']})")
    for i in issues:
        print(f"- {i['file']}:{i['line']} {i['rule']} -> {i['status']}")
    # Exit codes: non-zero for 'fail' when in 'enforce' mode
    if mode == 'enforce' and report['summary']['failures'] > 0:
        sys.exit(2)


if __name__ == '__main__':
    main()
