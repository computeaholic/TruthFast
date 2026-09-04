# Image: derived from current runner image to add python venv support
# This Dockerfile is intended to be used by infra to create a new ARC runner image
# that includes the system package(s) required for `python3 -m venv`.

FROM registry.threadforge.local:30500/actions-runner:make-20260119

# Ensure python venv packages exist for build-time virtualenv creation
# NOTE: do not change the USER here; keep base image default (runner user) to avoid startup issues
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12-venv \
    python3-venv \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Preserve entrypoint/cmd from upstream image

LABEL maintainer="threadforge-ops@threadforge.local"
