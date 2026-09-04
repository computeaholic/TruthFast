FROM kindest/node:v1.30.2

COPY .certs/ca.crt /usr/local/share/ca-certificates/threadforge-ingress-ca.crt
COPY .certs/ca.crt /etc/containerd/certs.d/threadforge-ingress-ca.crt
COPY .certs/ca.crt /etc/containerd/certs.d/registry.threadforge.local:30500/ca.crt
COPY .certs/ca.crt /etc/containerd/certs.d/docker.io/ca.crt
COPY .certs/ca.crt /etc/containerd/certs.d/registry.k8s.io/ca.crt
COPY .certs/ca.crt /etc/containerd/certs.d/gcr.io/ca.crt
COPY .certs/ca.crt /etc/containerd/certs.d/ghcr.io/ca.crt

RUN update-ca-certificates \
 && cat > /etc/containerd/certs.d/registry.threadforge.local:30500/hosts.toml <<'EOF'
server = "https://registry.threadforge.local:30500"

[host."https://registry.threadforge.local:30500"]
  capabilities = ["pull", "resolve", "push"]
  ca = ["/etc/containerd/certs.d/registry.threadforge.local:30500/ca.crt"]
EOF

RUN cat > /etc/containerd/certs.d/docker.io/hosts.toml <<'EOF'
server = "https://registry-1.docker.io"

[host."https://registry.threadforge.local:30500"]
  capabilities = ["pull", "resolve"]
  ca = ["/etc/containerd/certs.d/docker.io/ca.crt"]
EOF

RUN cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<'EOF'
server = "https://registry.k8s.io"

[host."https://registry.threadforge.local:30500"]
  capabilities = ["pull", "resolve"]
  ca = ["/etc/containerd/certs.d/registry.k8s.io/ca.crt"]
EOF

RUN cat > /etc/containerd/certs.d/gcr.io/hosts.toml <<'EOF'
server = "https://gcr.io"

[host."https://registry.threadforge.local:30500"]
  capabilities = ["pull", "resolve"]
  ca = ["/etc/containerd/certs.d/gcr.io/ca.crt"]
EOF

RUN cat > /etc/containerd/certs.d/ghcr.io/hosts.toml <<'EOF'
server = "https://ghcr.io"

[host."https://registry.threadforge.local:30500"]
  capabilities = ["pull", "resolve"]
  ca = ["/etc/containerd/certs.d/ghcr.io/ca.crt"]
EOF
