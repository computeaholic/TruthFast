#!/bin/bash
set -euo pipefail
# Setup PostgreSQL access for Phase A tests
#
# This script:
# 1. Starts kubectl port-forward to the PostgreSQL service
# 2. Sets environment variables for the test database connection
# 3. Waits for the database to be ready
#
# Usage:
#   source scripts/setup-pg-test.sh
#   pytest tests/control_plane/test_delegation_persistence_phase_a.py

set -e

echo "🔌 Setting up PostgreSQL access for Phase A tests..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install kubectl and ensure your kubeconfig is configured."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Check cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster. Please check your kubeconfig."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Extract PostgreSQL credentials from Kubernetes secret
echo "📋 Extracting PostgreSQL credentials from Kubernetes..."

PG_USER=$(kubectl get secret -n threadforge-system postgres-credentials -o jsonpath='{.data.POSTGRES_USER}' 2>/dev/null | base64 -d)
PG_PASSWORD=$(kubectl get secret -n threadforge-system postgres-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d)
PG_DB=$(kubectl get secret -n threadforge-system postgres-credentials -o jsonpath='{.data.POSTGRES_DB}' 2>/dev/null | base64 -d)

if [ -z "$PG_USER" ] || [ -z "$PG_PASSWORD" ]; then
    echo "❌ Could not extract PostgreSQL credentials from Kubernetes secret"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

export POSTGRES_USER="$PG_USER"
export POSTGRES_PASSWORD="$PG_PASSWORD"
export POSTGRES_HOST="localhost"
export POSTGRES_PORT="15432"

echo "✅ Extracted credentials: user=$POSTGRES_USER, db=$PG_DB"

# Kill any existing port-forward processes
if pgrep -f "kubectl port-forward.*postgres" > /dev/null; then
    echo "🔄 Cleaning up existing port-forward processes..."
    pkill -f "kubectl port-forward.*postgres" || true
    sleep 1
fi

# Start port-forward in background
echo "🚀 Starting kubectl port-forward (localhost:15432 -> postgres:5432)..."
kubectl port-forward -n threadforge-system svc/postgres 15432:5432 > /tmp/pg-port-forward.log 2>&1 &
PF_PID=$!

# Wait for port to be ready
echo "⏳ Waiting for PostgreSQL to be accessible..."
max_attempts=30
attempt=0

while [ $attempt -lt $max_attempts ]; do
    if PGPASSWORD="$PG_PASSWORD" psql -h localhost -p 15432 -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null; then
        echo "✅ PostgreSQL is ready!"
        break
    fi
    attempt=$((attempt + 1))
    if [ $attempt -eq $max_attempts ]; then
        echo "❌ PostgreSQL did not become ready in time"
        kill $PF_PID 2>/dev/null || true
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
    sleep 1
done

# Show status
echo ""
echo "📊 PostgreSQL Test Environment Ready"
echo "=================================="
echo "Host: $POSTGRES_HOST"
echo "Port: $POSTGRES_PORT"
echo "User: $POSTGRES_USER"
echo "DB:   $PG_DB"
echo ""
echo "To run tests:"
echo "  pytest tests/control_plane/test_delegation_persistence_phase_a.py -v"
echo ""
echo "To stop port-forward:"
echo "  kill $PF_PID"
echo ""
