#!/bin/bash

# Common functions and error handling for KServe Argo Rollout tests

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-kserve-rollout-test}"
NAMESPACE="${NAMESPACE:-default}"
TIMEOUT="${TIMEOUT:-300}"

# Error handler
error_handler() {
    local exit_code=$1
    local line_number=$2
    log_error "Script failed with exit code $exit_code at line $line_number"
    exit "$exit_code"
}

trap 'error_handler $? $LINENO' ERR

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_step() {
    echo ""
    echo -e "${GREEN}===================================================================${NC}"
    echo -e "${GREEN}$*${NC}"
    echo -e "${GREEN}===================================================================${NC}"
}

# Cluster helper functions
cluster_exists() {
    kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"
}

wait_for_cluster_ready() {
    log_info "Waiting for cluster to be ready..."
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if kubectl cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null; then
            log_success "Cluster is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        log_info "Waiting for cluster... (attempt $attempt/$max_attempts)"
        sleep 2
    done

    log_error "Cluster failed to become ready within timeout"
    return 1
}

# Kubernetes resource helpers
wait_for_pod() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}

    log_info "Waiting for pod with label '$label' in namespace '$namespace'..."
    kubectl wait --for=condition=Ready pod \
        -l "$label" \
        -n "$namespace" \
        --timeout="${timeout}s" 2>&1 | grep -v "no matching resources found" || true
}

wait_for_deployment() {
    local namespace=$1
    local name=$2
    local timeout=${3:-300}

    log_info "Waiting for deployment '$name' in namespace '$namespace'..."
    kubectl wait --for=condition=Available deployment/"$name" \
        -n "$namespace" \
        --timeout="${timeout}s"
}

wait_for_rollout() {
    local namespace=$1
    local name=$2
    local timeout=${3:-300}

    log_info "Waiting for rollout '$name' in namespace '$namespace'..."

    # Check if kubectl-argo-rollouts plugin is available
    if ! command -v kubectl-argo-rollouts &>/dev/null; then
        log_warn "kubectl-argo-rollouts plugin not found, using kubectl wait"
        kubectl wait --for=condition=Available rollout/"$name" \
            -n "$namespace" \
            --timeout="${timeout}s"
        return $?
    fi

    # Use argo rollouts plugin
    kubectl argo rollouts status "$name" \
        -n "$namespace" \
        --timeout="${timeout}s"
}

wait_for_isvc_ready() {
    local namespace=$1
    local name=$2
    local timeout=${3:-300}

    log_info "Waiting for InferenceService '$name' in namespace '$namespace' to be ready..."

    local end_time=$((SECONDS + timeout))
    while [ $SECONDS -lt $end_time ]; do
        local status
        status=$(kubectl get isvc "$name" -n "$namespace" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

        if [ "$status" = "True" ]; then
            log_success "InferenceService '$name' is ready"
            return 0
        fi

        log_info "InferenceService status: $status (waiting...)"
        sleep 5
    done

    log_error "InferenceService '$name' failed to become ready within ${timeout}s"
    kubectl get isvc "$name" -n "$namespace" -o yaml
    return 1
}

check_resource_exists() {
    local resource_type=$1
    local name=$2
    local namespace=$3

    if kubectl get "$resource_type" "$name" -n "$namespace" &>/dev/null; then
        log_success "Resource $resource_type/$name exists in namespace $namespace"
        return 0
    else
        log_error "Resource $resource_type/$name does NOT exist in namespace $namespace"
        return 1
    fi
}

check_resource_not_exists() {
    local resource_type=$1
    local name=$2
    local namespace=$3

    if kubectl get "$resource_type" "$name" -n "$namespace" &>/dev/null; then
        log_error "Resource $resource_type/$name exists in namespace $namespace (should NOT exist)"
        return 1
    else
        log_success "Resource $resource_type/$name does not exist (as expected)"
        return 0
    fi
}

get_service_endpoints() {
    local name=$1
    local namespace=$2

    kubectl get endpoints "$name" -n "$namespace" \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | tr ' ' '\n'
}

check_httproute_backend() {
    local name=$1
    local namespace=$2
    local expected_backend=$3

    local actual_backend
    actual_backend=$(kubectl get httproute "$name" -n "$namespace" \
        -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null || echo "")

    if [ "$actual_backend" = "$expected_backend" ]; then
        log_success "HTTPRoute backend is '$actual_backend' (as expected)"
        return 0
    else
        log_error "HTTPRoute backend is '$actual_backend', expected '$expected_backend'"
        return 1
    fi
}

# Inference testing
test_inference() {
    local url=$1
    local payload=$2
    local expected_status=${3:-200}

    log_info "Testing inference at $url"

    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null || echo -e "\n000")

    http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    if [ "$http_code" -eq "$expected_status" ]; then
        log_success "Inference successful (HTTP $http_code)"
        log_info "Response: $body"
        return 0
    else
        log_error "Inference failed (HTTP $http_code, expected $expected_status)"
        log_error "Response: $body"
        return 1
    fi
}

# Cleanup helpers
cleanup_isvc() {
    local name=$1
    local namespace=$2

    log_info "Cleaning up InferenceService '$name'..."
    if kubectl get isvc "$name" -n "$namespace" &>/dev/null; then
        kubectl delete isvc "$name" -n "$namespace" --ignore-not-found=true

        # Wait for resources to be cleaned up
        local timeout=60
        local elapsed=0
        while kubectl get isvc "$name" -n "$namespace" &>/dev/null; do
            if [ $elapsed -ge $timeout ]; then
                log_warn "InferenceService deletion timed out after ${timeout}s"
                break
            fi
            sleep 2
            elapsed=$((elapsed + 2))
        done

        log_success "InferenceService '$name' cleaned up"
    else
        log_info "InferenceService '$name' does not exist, skipping cleanup"
    fi
}

# Validation helpers
validate_rollout_status() {
    local name=$1
    local namespace=$2

    log_info "Validating rollout status in InferenceService..."

    local rollout_status
    rollout_status=$(kubectl get isvc "$name" -n "$namespace" \
        -o jsonpath='{.status.components.predictor.rolloutStatus}' 2>/dev/null || echo "")

    if [ -n "$rollout_status" ]; then
        log_success "RolloutStatus is populated: $rollout_status"

        # Check phase
        local phase
        phase=$(kubectl get isvc "$name" -n "$namespace" \
            -o jsonpath='{.status.components.predictor.rolloutStatus.phase}' 2>/dev/null || echo "")
        log_info "Rollout phase: $phase"

        return 0
    else
        log_error "RolloutStatus is NOT populated in InferenceService status"
        return 1
    fi
}

count_services() {
    local name_pattern=$1
    local namespace=$2

    kubectl get svc -n "$namespace" --no-headers 2>/dev/null | grep "$name_pattern" | wc -l | tr -d ' '
}

# Display helpers
show_resources() {
    local name=$1
    local namespace=$2

    log_info "Current resources for '$name' in namespace '$namespace':"
    echo ""
    echo "Deployments:"
    kubectl get deployment -n "$namespace" -l serving.kserve.io/inferenceservice="$name" 2>/dev/null || echo "  None"
    echo ""
    echo "Rollouts:"
    kubectl get rollout -n "$namespace" -l serving.kserve.io/inferenceservice="$name" 2>/dev/null || echo "  None"
    echo ""
    echo "Services:"
    kubectl get svc -n "$namespace" | grep "$name" || echo "  None"
    echo ""
    echo "HTTPRoutes:"
    kubectl get httproute -n "$namespace" -l serving.kserve.io/inferenceservice="$name" 2>/dev/null || echo "  None"
    echo ""
}

# Verification summary
print_verification_summary() {
    local test_name=$1
    shift
    local -a results=("$@")

    echo ""
    log_step "Verification Summary: $test_name"

    local total=${#results[@]}
    local passed=0
    local failed=0

    for result in "${results[@]}"; do
        if [[ $result == PASS:* ]]; then
            passed=$((passed + 1))
            echo -e "${GREEN}✓${NC} ${result#PASS:}"
        else
            failed=$((failed + 1))
            echo -e "${RED}✗${NC} ${result#FAIL:}"
        fi
    done

    echo ""
    if [ $failed -eq 0 ]; then
        log_success "All $total checks passed!"
        return 0
    else
        log_error "$failed out of $total checks failed"
        return 1
    fi
}

# Check required commands
check_required_commands() {
    local -a required_commands=("kind" "kubectl" "docker" "curl")
    local missing=0

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            missing=$((missing + 1))
        fi
    done

    if [ $missing -gt 0 ]; then
        log_error "$missing required commands are missing"
        return 1
    fi

    log_success "All required commands are available"
    return 0
}

# Export functions for use in other scripts
export -f log_info log_success log_warn log_error log_step
export -f cluster_exists wait_for_cluster_ready
export -f wait_for_pod wait_for_deployment wait_for_rollout wait_for_isvc_ready
export -f check_resource_exists check_resource_not_exists
export -f get_service_endpoints check_httproute_backend
export -f test_inference cleanup_isvc
export -f validate_rollout_status count_services show_resources
export -f print_verification_summary check_required_commands
