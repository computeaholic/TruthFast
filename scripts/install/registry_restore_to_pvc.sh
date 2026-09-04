#!/usr/bin/env bash
set -euo pipefail
BACKUP=${1:?backup tar file}
PVC=${2:-registry-data-pvc}
NAMESPACE=${3:-registry}
PODNAME=registry-restore-init-$(date -u +%s)

echo "Using backup: $BACKUP -> PVC: $PVC namespace: $NAMESPACE"
# Create a temporary pod that mounts the PVC and extracts the backup
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${PODNAME}
  namespace: ${NAMESPACE}
spec:
  containers:
    - name: restore
      image: alpine:3.18
      command: ["/bin/sh","-c","sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  restartPolicy: Never
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${PVC}
YAML

echo "Waiting for pod to be running..."
kubectl wait --for=condition=Ready pod/${PODNAME} -n ${NAMESPACE} --timeout=120s

# Copy backup into pod
kubectl cp "$BACKUP" ${NAMESPACE}/${PODNAME}:/tmp/backup.tgz

# Extract into /data
kubectl exec -n ${NAMESPACE} ${PODNAME} -- sh -c "tar -C /data -xzf /tmp/backup.tgz"

# Cleanup the init pod
kubectl delete pod -n ${NAMESPACE} ${PODNAME} --wait

echo "Restore to PVC ${PVC} completed"
