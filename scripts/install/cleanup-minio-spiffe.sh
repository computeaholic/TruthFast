#!/bin/bash
set -euo pipefail
# ThreadForge PPIT-INT Enforcement — MinIO Cleanup Script
#
# Removes MinIO from SPIFFE/Istio identity plane
# Prepares for PPIT-INT mutual TLS only

set -e

echo "🧹 Cleaning up legacy MinIO SPIFFE/Istio configurations..."

# Remove SPIRE registration for MinIO
echo "Removing SPIRE registration for MinIO..."
kubectl delete job spire-register-minio -n spire-system --ignore-not-found=true

# Remove SPIRE WorkloadEntry (if it exists)
echo "Removing SPIRE WorkloadEntry for MinIO..."
kubectl delete workloadentry minio -n minio --ignore-not-found=true

# Remove Istio security policies
echo "Removing Istio PeerAuthentication for MinIO..."
kubectl delete peerauthentication minio-strict -n minio --ignore-not-found=true

echo "Removing Istio AuthorizationPolicy for MinIO..."
kubectl delete authorizationpolicy minio-allow-tempo -n minio --ignore-not-found=true

echo "Removing Istio DestinationRule for MinIO..."
kubectl delete destinationrule minio-mtls -n minio --ignore-not-found=true

# Remove Envoy port exclusions
echo "Removing Envoy port exclusions for MinIO..."
kubectl patch deployment minio -n minio --type='json' -p='[{"op": "remove", "path": "/spec/template/metadata/annotations/traffic.sidecar.istio.io~1excludeInboundPorts"}]'

# Remove SPIFFE CSI volume mounts (if they exist)
echo "Checking for SPIFFE CSI mounts..."
if kubectl get deployment minio -n minio -o yaml | grep -q "sidecar.istio.io/userVolume"; then
    echo "Deprecated Istio sidecar socket annotations found - manual cleanup required"
    echo "Please remove sidecar.istio.io/userVolume and sidecar.istio.io/userVolumeMount from MinIO deployment"
fi

# Disable Istio injection for MinIO namespace
echo "Disabling Istio injection for minio namespace..."
kubectl label namespace minio istio-injection=disabled --overwrite

# Remove any remaining AuthorizationPolicy objects
echo "Checking for remaining AuthorizationPolicy objects..."
kubectl get authorizationpolicy -n minio

echo "✅ Legacy MinIO SPIFFE/Istio cleanup complete"
echo ""
echo "📋 Next steps:"
echo "1. Apply new PPIT-INT MinIO configuration: kubectl apply -f deploy/services/minio/minio-ppit-int.yaml"
echo "2. Apply PPIT Mint service: kubectl apply -f deploy/services/ppit/ppit-mint-service.yaml"
echo "3. Update workload deployments to use PPIT client for MinIO access"
echo "4. Test PPIT-INT certificate authentication"
