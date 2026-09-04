#!/usr/bin/env bash

# The SPIRE install producer publishes the admin socket at the configured
# admin_socket_path. Consumers must share this contract instead of selecting a
# data-directory or legacy path independently.
SPIRE_SERVER_SOCKET_PATH="${SPIRE_SERVER_SOCKET_PATH:-/run/spire/private/spire-server.sock}"
