#!/usr/bin/env bash
set -euo pipefail

RULE="/usr/bin/cat /etc/rancher/k3s/k3s.yaml"

echo "🔐 Adding safe passwordless sudo rule for user 'threadforge'..."
echo "threadforge ALL=(ALL) NOPASSWD: ${RULE}" | sudo tee /etc/sudoers.d/threadforge-k3s > /dev/null

echo "✔ Sudo rule installed:"
sudo cat /etc/sudoers.d/threadforge-k3s
