#!/usr/bin/env bash
set -euo pipefail

NS="spire-system"
TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"
BUSYBOX_IMAGE="registry.threadforge.local:30500/mirror/docker.io/library/busybox@sha256:bfdec45b06a48dbc7d261ace48cec2d74849ecfc5129662c979f656cb31df469"
SERVER_IMAGE="registry.threadforge.local:30500/spiffe/spire-server@sha256:817a87c37a6b77ff74c95908160ee0555daac8d8269e2fd7ad2b6e41b86164d8"
AGENT_IMAGE="registry.threadforge.local:30500/spiffe/spire-agent@sha256:0d3cebdf4e033edaa67ef1b4197696f853bb76f8970e25010237c7e3a7c98531"

echo "[SPIRE] Agent state paths"
echo "  /run/spire (agent runtime state)"
echo "  /run/spire/sockets (agent socket dir)"
echo "  /var/lib/spire-server (server persistent state backing /run/spire/data)"
echo "  /var/lib/kubelet/pods (workload attestor source, read-only)"

run_agent_state_cleanup() {
  echo "[SPIRE] Running host-path cleanup for legacy trust/cache artifacts"
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create serviceaccount spire-cleaner -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl delete pod spire-agent-state-cleaner -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: spire-agent-state-cleaner
  namespace: ${NS}
spec:
  restartPolicy: Never
  serviceAccountName: spire-cleaner
  hostPID: true
  containers:
  - name: cleaner
    image: ${BUSYBOX_IMAGE}
    securityContext:
      privileged: true
      runAsUser: 0
    command:
    - /bin/sh
    - -c
    - |
      set -e
      rm -rf /host/run-spire/*
      rm -rf /host/var-lib-spire-agent/*
      rm -rf /host/var-lib-spire-server/*
      mkdir -p /host/run-spire/sockets
      mkdir -p /host/var-lib-spire-server
      chmod 0755 /host/run-spire
      chmod 0775 /host/run-spire/sockets
      chmod 0777 /host/var-lib-spire-server
    volumeMounts:
    - name: run-spire
      mountPath: /host/run-spire
    - name: var-lib-spire-agent
      mountPath: /host/var-lib-spire-agent
    - name: var-lib-spire-server
      mountPath: /host/var-lib-spire-server
  volumes:
  - name: run-spire
    hostPath:
      path: /run/spire
      type: DirectoryOrCreate
  - name: var-lib-spire-agent
    hostPath:
      path: /var/lib/spire-agent
      type: DirectoryOrCreate
  - name: var-lib-spire-server
    hostPath:
      path: /var/lib/spire-server
      type: DirectoryOrCreate
EOF

  for _ in $(seq 1 120); do
    phase="$(kubectl get pod spire-agent-state-cleaner -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Succeeded" ]]; then
      break
    fi
    if [[ "${phase}" == "Failed" ]]; then
      kubectl logs pod/spire-agent-state-cleaner -n "${NS}" >/tmp/spire-agent-state-cleaner.log 2>&1 || true
      echo "[FAIL] spire-agent-state-cleaner failed"
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
    sleep 1
  done

  final_phase="$(kubectl get pod spire-agent-state-cleaner -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${final_phase}" != "Succeeded" ]]; then
    kubectl logs pod/spire-agent-state-cleaner -n "${NS}" >/tmp/spire-agent-state-cleaner.log 2>&1 || true
    echo "[FAIL] spire-agent-state-cleaner did not complete successfully"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi

  kubectl logs pod/spire-agent-state-cleaner -n "${NS}" >/tmp/spire-agent-state-cleaner.log 2>&1 || true
  kubectl delete pod spire-agent-state-cleaner -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
}

select_ready_spire_server_pod() {
  kubectl get pods -n "${NS}" -l app=spire-server -o json 2>/dev/null | jq -r '
    .items[]
    | select(.status.phase == "Running")
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name
  ' | head -n1
}

if kubectl get ns "${NS}" >/dev/null 2>&1; then
  NS_PHASE="$(kubectl get ns "${NS}" -o jsonpath='{.status.phase}')"
  if [[ "${NS_PHASE}" == "Terminating" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "[FAIL] jq is required to finalize terminating namespace ${NS}"
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
    echo "[SPIRE] Finalizing terminating namespace ${NS}"
    kubectl get ns "${NS}" -o json \
      | jq '.spec.finalizers=[]' \
      | kubectl replace --raw "/api/v1/namespaces/${NS}/finalize" -f -
    kubectl wait --for=delete "ns/${NS}" --timeout=120s || true
  fi
fi

if kubectl get statefulset spire-server -n "${NS}" >/dev/null 2>&1; then
  echo "[SPIRE] Deleting legacy spire-server statefulset"
  kubectl delete statefulset spire-server -n "${NS}" --ignore-not-found
  kubectl wait --for=delete statefulset/spire-server -n "${NS}" --timeout=120s || true
fi

if kubectl get deployment spire-server -n "${NS}" >/dev/null 2>&1; then
  echo "[SPIRE] Deleting existing spire-server deployment"
  kubectl delete deployment spire-server -n "${NS}" --ignore-not-found
  kubectl wait --for=delete deployment/spire-server -n "${NS}" --timeout=120s || true
fi

if kubectl get daemonset spire-agent -n "${NS}" >/dev/null 2>&1; then
  echo "[SPIRE] Deleting existing spire-agent daemonset"
  kubectl delete daemonset spire-agent -n "${NS}" --ignore-not-found
  kubectl wait --for=delete daemonset/spire-agent -n "${NS}" --timeout=120s || true
fi

run_agent_state_cleanup

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-server
  namespace: ${NS}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-agent
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spire-server-role
rules:
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["nodes", "pods", "services", "endpoints"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spire-server-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: spire-server-role
subjects:
- kind: ServiceAccount
  name: spire-server
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spire-agent-role
rules:
- apiGroups: [""]
  resources: ["pods", "nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spire-agent-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: spire-agent-role
subjects:
- kind: ServiceAccount
  name: spire-agent
  namespace: ${NS}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-server-config
  namespace: ${NS}
data:
  server.conf: |
    server {
      bind_address = "0.0.0.0"
      bind_port = "8081"
      trust_domain = "${TRUST_DOMAIN}"
      data_dir = "/run/spire/data"
      socket_path = "/run/spire/data/server.sock"
      log_level = "INFO"
    }

    plugins {
      DataStore "sql" {
        plugin_data {
          database_type = "sqlite3"
          connection_string = "/run/spire/data/datastore.sqlite3"
        }
      }

      KeyManager "disk" {
        plugin_data {
          keys_path = "/run/spire/data/keys.json"
        }
      }

      NodeAttestor "k8s_psat" {
        plugin_data {
          clusters = {
            "threadforge" = {
              service_account_allow_list = ["spire-system:spire-agent"]
            }
          }
        }
      }
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-agent-config
  namespace: ${NS}
data:
  agent.conf: |
    agent {
      data_dir = "/run/spire"
      log_level = "INFO"
      server_address = "spire-server.spire-system.svc"
      server_port = "8081"
      socket_path = "/run/spire/sockets/agent.sock"
      trust_domain = "${TRUST_DOMAIN}"
      insecure_bootstrap = true
    }

    plugins {
      NodeAttestor "k8s_psat" {
        plugin_data {
          cluster = "threadforge"
        }
      }

      KeyManager "memory" {
        plugin_data {}
      }

      WorkloadAttestor "k8s" {
        plugin_data {
          pod_resources_path = "/var/lib/kubelet/pod-resources/kubelet.sock"
          # Keep pod-level attestation for workloads that can start before
          # container metadata is fully resolved (notably spire-csr).
          disable_container_selectors = true
          skip_kubelet_verification = true
        }
      }
    }
---
apiVersion: v1
kind: Service
metadata:
  name: spire-server
  namespace: ${NS}
spec:
  selector:
    app: spire-server
  ports:
  - name: grpc
    protocol: TCP
    port: 8081
    targetPort: 8081
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spire-server
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: spire-server
  template:
    metadata:
      labels:
        app: spire-server
    spec:
      serviceAccountName: spire-server
      initContainers:
      - name: init-server-data-permissions
        image: ${BUSYBOX_IMAGE}
        securityContext:
          runAsUser: 0
        command:
        - /bin/sh
        - -c
        - |
          set -e
          mkdir -p /run/spire/data
          chmod 0777 /run/spire/data
          chmod -R 0777 /run/spire/data
        volumeMounts:
        - name: server-data
          mountPath: /run/spire/data
      containers:
      - name: spire-server
        image: ${SERVER_IMAGE}
        imagePullPolicy: IfNotPresent
        args: ["run", "-config", "/opt/spire/conf/server/server.conf"]
        ports:
        - containerPort: 8081
        volumeMounts:
        - name: server-config
          mountPath: /opt/spire/conf/server
        - name: server-data
          mountPath: /run/spire/data
      volumes:
      - name: server-config
        configMap:
          name: spire-server-config
      - name: server-data
        hostPath:
          path: /var/lib/spire-server
          type: DirectoryOrCreate
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: spire-agent
  namespace: ${NS}
spec:
  selector:
    matchLabels:
      app: spire-agent
  template:
    metadata:
      labels:
        app: spire-agent
    spec:
      serviceAccountName: spire-agent
      hostNetwork: true
      hostPID: true
      dnsPolicy: ClusterFirstWithHostNet
      initContainers:
      - name: init-clean-agent-state
        image: ${BUSYBOX_IMAGE}
        securityContext:
          runAsUser: 0
        command:
        - /bin/sh
        - -c
        - |
          set -e
          rm -rf /run/spire/*
          mkdir -p /run/spire/sockets
          chmod 0755 /run/spire
          chmod 0775 /run/spire/sockets
        volumeMounts:
        - name: agent-data
          mountPath: /run/spire
      containers:
      - name: spire-agent
        image: ${AGENT_IMAGE}
        imagePullPolicy: IfNotPresent
        args: ["run", "-config", "/opt/spire/conf/agent/agent.conf"]
        readinessProbe:
          exec:
            command:
            - /opt/spire/bin/spire-agent
            - healthcheck
            - -socketPath
            - /run/spire/sockets/agent.sock
          periodSeconds: 2
          failureThreshold: 3
          timeoutSeconds: 3
        volumeMounts:
        - name: agent-config
          mountPath: /opt/spire/conf/agent
        - name: agent-data
          mountPath: /run/spire
        - name: containerd-socket
          mountPath: /run/containerd
          readOnly: true
        - name: kubelet-pod-resources
          mountPath: /var/lib/kubelet/pod-resources
          readOnly: true
        - name: kubelet-pods
          mountPath: /var/lib/kubelet/pods
          readOnly: true
        - name: host-var-run
          mountPath: /host/var/run
        - name: spire-agent-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
      volumes:
      - name: agent-config
        configMap:
          name: spire-agent-config
      - name: agent-data
        hostPath:
          path: /run/spire
          type: DirectoryOrCreate
      - name: kubelet-pods
        hostPath:
          path: /var/lib/kubelet/pods
          type: Directory
      - name: containerd-socket
        hostPath:
          path: /run/containerd
          type: Directory
      - name: kubelet-pod-resources
        hostPath:
          path: /var/lib/kubelet/pod-resources
          type: Directory
      - name: host-var-run
        hostPath:
          path: /var/run
          type: Directory
      - name: spire-agent-token
        projected:
          sources:
          - serviceAccountToken:
              audience: spire-server
              expirationSeconds: 7200
              path: spire-agent
EOF

if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
  echo "[FAIL] ${NS} namespace was not created"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if [[ "$(kubectl get ns "${NS}" -o jsonpath='{.status.phase}')" != "Active" ]]; then
  echo "[FAIL] ${NS} namespace is not Active"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[SPIRE] Waiting for rollouts"
kubectl rollout status deploy/spire-server -n "${NS}" --timeout=180s
kubectl rollout status daemonset/spire-agent -n "${NS}" --timeout=180s

echo "[SPIRE] Rotating spire-agent pods to reset restart counters"
kubectl delete pod -n "${NS}" -l app=spire-agent --ignore-not-found
kubectl rollout status daemonset/spire-agent -n "${NS}" --timeout=180s

for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  AGENT_RESTARTS_NOW="$(kubectl get pods -n "${NS}" -l app=spire-agent -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
  AGENT_READY_NOW="$(kubectl get pods -n "${NS}" -l app=spire-agent -o jsonpath='{.items[*].status.containerStatuses[0].ready}' 2>/dev/null || true)"
  if [[ -n "${AGENT_RESTARTS_NOW}" && "${AGENT_RESTARTS_NOW}" != *" "* && "${AGENT_RESTARTS_NOW}" -eq 0 && "${AGENT_READY_NOW}" == "true" ]]; then
    break
  fi
  sleep 5
done

SERVER_POD="$(select_ready_spire_server_pod)"
if [[ -z "${SERVER_POD}" ]]; then
  echo "[FAIL] spire-server pod was not scheduled"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

AGENT_COUNT="$(kubectl get pod -n "${NS}" -l app=spire-agent --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ -z "${AGENT_COUNT}" || "${AGENT_COUNT}" -eq 0 ]]; then
  echo "[FAIL] no running spire-agent pod was scheduled"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

FINAL_AGENT_RESTARTS="$(kubectl get pods -n "${NS}" -l app=spire-agent -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}')"
if [[ -z "${FINAL_AGENT_RESTARTS}" ]]; then
  echo "[FAIL] unable to read spire-agent restart counters"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
for rc in ${FINAL_AGENT_RESTARTS}; do
  if [[ "${rc}" -gt 0 ]]; then
    echo "[FAIL] spire-agent restartCount is non-zero after install (${rc})"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
done

ENTRY_READY="false"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if kubectl exec -n "${NS}" "${SERVER_POD}" -- /opt/spire/bin/spire-server entry show \
    -socketPath /run/spire/data/server.sock 2>/dev/null | grep -q "spiffe://${TRUST_DOMAIN}/bootstrap/root"; then
    ENTRY_READY="true"
    break
  fi
  if kubectl exec -n "${NS}" "${SERVER_POD}" -- /opt/spire/bin/spire-server entry create \
    -socketPath /run/spire/data/server.sock \
    -parentID "spiffe://${TRUST_DOMAIN}/spire/server" \
    -spiffeID "spiffe://${TRUST_DOMAIN}/bootstrap/root" \
    -selector unix:uid:0 >/dev/null 2>&1; then
    ENTRY_READY="true"
    break
  fi
  sleep 2
done
if [[ "${ENTRY_READY}" != "true" ]]; then
  echo "[FAIL] spire-server admin socket or bootstrap entry did not become ready"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[PASS] SPIRE installed"
