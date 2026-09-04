#!/usr/bin/env bash
set -euo pipefail

load_ref() {
  local ref="$1"
  kind load docker-image "$ref" --name threadforge >/dev/null 2>&1 || true
}

load_ref registry.threadforge.local:30500/istio/pilot@sha256:32515653577393f5e6375ccc1350a0cf0aabdd733f8fe9265bb51003a10be26f
load_ref registry.threadforge.local:30500/istio/proxyv2@sha256:2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b
load_ref registry.threadforge.local:30500/kyverno/kyverno@sha256:8806a3d49f236050b94928c61dea890cb41f7c77d16c59c005a5b1f930effa30
load_ref registry.threadforge.local:30500/kyverno/kyvernopre@sha256:9664f553dc92a1b31c4176c541ba7fea7155ef702516ac36b0170ffb0e47c65e
load_ref registry.threadforge.local:30500/kyverno/background-controller@sha256:930f4ac6d54babf3d2501eb49f59df39fa93e962a2ce55d73e3dce5d656f2c0d
load_ref registry.threadforge.local:30500/kyverno/cleanup-controller@sha256:0403d324b4f9a88182a82453330b0b0549bd971fda52c28d5240b0b0e64ee8a8
load_ref registry.threadforge.local:30500/kyverno/reports-controller@sha256:1594ec21d76b87dffef2ff6b4f3c6de0453c4429c05ab7de4bf4b23babc99b8e
load_ref registry.threadforge.local:30500/spiffe/spire-agent@sha256:8808bf2310024e0734b4ff2ea28d7d74963335b9bba0694a259fe405c473a4ce
load_ref registry.threadforge.local:30500/spiffe/spire-server@sha256:817a87c37a6b77ff74c95908160ee0555daac8d8269e2fd7ad2b6e41b86164d8
load_ref registry.threadforge.local:30500/mirror/docker.io/library/busybox@sha256:bfdec45b06a48dbc7d261ace48cec2d74849ecfc5129662c979f656cb31df469
load_ref registry.threadforge.local:30500/mirror/docker.io/bitnami/kubectl@sha256:a84ef19c1c38286cb674c90182bd8b4e1d11ed4e089e5994f553cbe5d67d9068

kubectl -n istio-system set image deployment/istiod discovery=registry.threadforge.local:30500/istio/pilot@sha256:32515653577393f5e6375ccc1350a0cf0aabdd733f8fe9265bb51003a10be26f
kubectl -n istio-system set image deployment/istio-ingressgateway istio-proxy=registry.threadforge.local:30500/istio/proxyv2@sha256:2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b

kubectl -n kyverno set image deployment/kyverno-admission-controller kyverno=registry.threadforge.local:30500/kyverno/kyverno@sha256:8806a3d49f236050b94928c61dea890cb41f7c77d16c59c005a5b1f930effa30
kubectl -n kyverno patch deployment kyverno-admission-controller --type='json' -p='[{"op":"replace","path":"/spec/template/spec/initContainers/0/image","value":"registry.threadforge.local:30500/kyverno/kyvernopre@sha256:9664f553dc92a1b31c4176c541ba7fea7155ef702516ac36b0170ffb0e47c65e"}]'
kubectl -n kyverno set image deployment/kyverno-background-controller kyverno=registry.threadforge.local:30500/kyverno/background-controller@sha256:930f4ac6d54babf3d2501eb49f59df39fa93e962a2ce55d73e3dce5d656f2c0d
kubectl -n kyverno set image deployment/kyverno-cleanup-controller kyverno=registry.threadforge.local:30500/kyverno/cleanup-controller@sha256:0403d324b4f9a88182a82453330b0b0549bd971fda52c28d5240b0b0e64ee8a8
kubectl -n kyverno set image deployment/kyverno-reports-controller kyverno=registry.threadforge.local:30500/kyverno/reports-controller@sha256:1594ec21d76b87dffef2ff6b4f3c6de0453c4429c05ab7de4bf4b23babc99b8e
for cj in kyverno-cleanup-admission-reports kyverno-cleanup-cluster-admission-reports kyverno-cleanup-cluster-ephemeral-reports kyverno-cleanup-ephemeral-reports kyverno-cleanup-update-requests; do
  kubectl -n kyverno set image cronjob/$cj cleanup=registry.threadforge.local:30500/mirror/docker.io/bitnami/kubectl@sha256:a84ef19c1c38286cb674c90182bd8b4e1d11ed4e089e5994f553cbe5d67d9068 >/dev/null 2>&1 || true
done

kubectl -n spire-system set image daemonset/spire-agent spire-agent=registry.threadforge.local:30500/spiffe/spire-agent@sha256:8808bf2310024e0734b4ff2ea28d7d74963335b9bba0694a259fe405c473a4ce
kubectl -n spire-system set image statefulset/spire-server spire-server=registry.threadforge.local:30500/spiffe/spire-server@sha256:817a87c37a6b77ff74c95908160ee0555daac8d8269e2fd7ad2b6e41b86164d8
kubectl -n spire-system patch daemonset spire-agent --type='json' -p='[{"op":"replace","path":"/spec/template/spec/initContainers/0/image","value":"registry.threadforge.local:30500/mirror/docker.io/library/busybox@sha256:bfdec45b06a48dbc7d261ace48cec2d74849ecfc5129662c979f656cb31df469"}]'
kubectl -n spire-system patch statefulset spire-server --type='json' -p='[{"op":"replace","path":"/spec/template/spec/initContainers/0/image","value":"registry.threadforge.local:30500/mirror/docker.io/library/busybox@sha256:bfdec45b06a48dbc7d261ace48cec2d74849ecfc5129662c979f656cb31df469"}]'

echo "patched"
