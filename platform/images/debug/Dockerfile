# ------------------------------------------------------------------
# ThreadForge — Operational Debug Image (non-evaluated)
# Purpose: Operational debugging only. Not part of the evaluated runtime.
# ------------------------------------------------------------------
FROM registry.threadforge.local:30500/mirror/docker.io/library/alpine:3.19

RUN apk add --no-cache \
    curl \
    ca-certificates \
    bind-tools \
    iproute2 \
    busybox-extras \
    jq \
    openssl

WORKDIR /debug

ENTRYPOINT ["/bin/sh"]
