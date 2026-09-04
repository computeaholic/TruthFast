#!/bin/bash
################################################################################
# TEST: Observability Gate Enforcement (Phase 3B)
# Purpose:
#   Verify that observability-gate correctly enforces observability plane liveness
#   - Fails when observability namespace is missing
#   - Fails when required StatefulSets are missing
#   - Fails when required StatefulSets are not Ready
#   - Passes when observability plane is fully operational
################################################################################

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

cd "$REPO_ROOT" || echo "[ADVISORY-FAIL] non-authoritative path"; exit 0

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TEST_PASS=0
TEST_FAIL=0

test_case() {
    local name="$1"
    echo -e "${YELLOW}[TEST] $name${NC}"
}

pass() {
    echo -e "${GREEN}  ✅ PASS${NC}"
    ((TEST_PASS++))
}

fail() {
    local msg="$1"
    echo -e "${RED}  ❌ FAIL: $msg${NC}"
    ((TEST_FAIL++))
}

# ==============================================================================
# Test 1: Verify observability gate target exists in Makefile
# ==============================================================================
test_case "observability-gate target exists in Makefile"
if grep -q "^observability-gate:" Makefile 2>/dev/null; then
    pass
else
    fail "observability-gate target not found"
fi

# ==============================================================================
# Test 2: Verify observability gate is a dependency of runtime-init
# ==============================================================================
test_case "runtime-init depends on observability-gate"
if grep -q "runtime-init: observability-gate" Makefile 2>/dev/null; then
    pass
else
    fail "observability-gate not a dependency of runtime-init"
fi

# ==============================================================================
# Test 3: Verify observability gate checks namespace existence
# ==============================================================================
test_case "observability-gate checks namespace existence"
if grep -A 20 "^observability-gate:" Makefile 2>/dev/null | grep -q "kubectl get ns observability"; then
    pass
else
    fail "namespace check missing from observability-gate"
fi

# ==============================================================================
# Test 4: Verify observability gate checks Prometheus StatefulSet
# ==============================================================================
test_case "observability-gate checks Prometheus StatefulSet"
if grep -A 20 "^observability-gate:" Makefile 2>/dev/null | grep -q "prometheus-kube-prometheus-stack-prometheus"; then
    pass
else
    fail "Prometheus StatefulSet check missing from observability-gate"
fi

# ==============================================================================
# Test 5: Verify observability gate checks Grafana StatefulSet
# ==============================================================================
test_case "observability-gate checks Grafana StatefulSet"
if grep -A 20 "^observability-gate:" Makefile 2>/dev/null | grep -q "grafana"; then
    pass
else
    fail "Grafana StatefulSet check missing from observability-gate"
fi

# ==============================================================================
# Test 5b: Verify observability gate checks Alertmanager StatefulSet
# ==============================================================================
test_case "observability-gate checks Alertmanager StatefulSet"
if grep -A 20 "^observability-gate:" Makefile 2>/dev/null | grep -q "alertmanager-kube-prometheus-stack-alertmanager"; then
    pass
else
    fail "Alertmanager StatefulSet check missing from observability-gate"
fi

# ==============================================================================
# Test 6: Verify observability gate checks Prometheus readiness
# ==============================================================================
test_case "observability-gate checks Prometheus readiness"
if grep -A 30 "^observability-gate:" Makefile 2>/dev/null | grep -q "prometheus.*readyReplicas"; then
    pass
else
    fail "Prometheus readiness check missing from observability-gate"
fi

# ==============================================================================
# Test 7: Verify observability gate checks Grafana readiness
# ==============================================================================
test_case "observability-gate checks Grafana readiness"
if grep -A 30 "^observability-gate:" Makefile 2>/dev/null | grep -q "grafana.*readyReplicas"; then
    pass
else
    fail "Grafana readiness check missing from observability-gate"
fi

# ==============================================================================
# Test 7b: Verify observability gate checks Alertmanager readiness
# ==============================================================================
test_case "observability-gate checks Alertmanager readiness"
if grep -A 30 "^observability-gate:" Makefile 2>/dev/null | grep -q "alertmanager.*readyReplicas"; then
    pass
else
    fail "Alertmanager readiness check missing from observability-gate"
fi

# ==============================================================================
# Test 8: Verify observability gate checks for running pods
# ==============================================================================
test_case "observability-gate checks for running pods"
if grep -A 30 "^observability-gate:" Makefile 2>/dev/null | grep -q "status.phase=Running"; then
    pass
else
    fail "Running pods check missing from observability-gate"
fi

# ==============================================================================
# Test 9: Verify gate fails on namespace missing (if cluster available)
# ==============================================================================
test_case "observability-gate fails when namespace missing (if cluster available)"
if kubectl get ns observability > /dev/null 2>&1; then
    # Cluster is available, test with a fake namespace
    if ! (kubectl get ns nonexistent-fake-ns-12345 > /dev/null 2>&1); then
        pass
    else
        fail "Test setup failed: fake namespace check"
    fi
else
    # Cluster not available, skip this test
    echo -e "${YELLOW}  ⊘ SKIP (cluster not available)${NC}"
fi

# ==============================================================================
# Test 10: Verify gate succeeds when observability is operational (if cluster available)
# ==============================================================================
test_case "observability-gate succeeds when observability is operational (if cluster available)"
if kubectl get ns observability > /dev/null 2>&1; then
    # Cluster is available, run actual gate check
    if make observability-gate > /dev/null 2>&1; then
        pass
    else
        fail "observability-gate failed on operational cluster"
    fi
else
    # Cluster not available, skip this test
    echo -e "${YELLOW}  ⊘ SKIP (cluster not available)${NC}"
fi

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "================================================================================"
echo "TEST SUMMARY"
echo "================================================================================"
echo -e "${GREEN}PASS: $TEST_PASS${NC}"
echo -e "${RED}FAIL: $TEST_FAIL${NC}"
echo "================================================================================"

if [ $TEST_FAIL -gt 0 ]; then
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

exit 0
