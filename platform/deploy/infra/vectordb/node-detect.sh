#!/usr/bin/env bash
# ==============================================================================
# ThreadForge — GPU/ANE Node Detector
# Detects GPU, CUDA, Metal/ANE, or Vulkan capability inside Lima VM
# and applies correct Kubernetes node labels.
# ==============================================================================

set -euo pipefail

echo "🔍 Detecting hardware acceleration..."

GPU="none"
ANE="false"

# --- Detect CUDA ---
if command -v nvidia-smi >/dev/null 2>&1; then
    echo "✔ NVIDIA GPU detected (CUDA available)"
    GPU="cuda"
fi

# --- Detect Vulkan (software or GPU-backed) ---
if command -v vulkaninfo >/dev/null 2>&1; then
    echo "✔ Vulkan runtime detected"
    if [ "$GPU" = "none" ]; then
        GPU="vulkan"
    fi
fi

# --- Detect Apple ANE inside Lima (rare, but possible w/ Metal passthrough) ---
if sysctl -a 2>/dev/null | grep -q "machdep.cpu.features:.*ANE"; then
    ANE="true"
    echo "✔ Apple Neural Engine detected"
fi

echo "📡 Applying node labels..."
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

kubectl label nodes "$NODE" threadforge.io/gpu="$GPU" --overwrite
kubectl label nodes "$NODE" threadforge.io/ane="$ANE" --overwrite

echo "✔ Node capabilities labeled:"
echo "   - GPU: $GPU"
echo "   - ANE: $ANE"
