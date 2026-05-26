#!/bin/bash

# Cleanup kind cluster and resources

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

cleanup_resources() {
    log_step "Cleaning up InferenceService resources"

    # Delete any remaining InferenceServices
    log_info "Deleting InferenceServices in namespace $NAMESPACE..."
    kubectl delete isvc --all -n "$NAMESPACE" --ignore-not-found=true --wait=true --timeout=60s

    log_success "InferenceService resources cleaned up"
}

delete_cluster() {
    log_step "Deleting kind cluster"

    if ! cluster_exists; then
        log_warn "Cluster '$CLUSTER_NAME' does not exist"
        return 0
    fi

    log_info "Deleting cluster '$CLUSTER_NAME'..."
    if kind delete cluster --name "$CLUSTER_NAME"; then
        log_success "Cluster deleted successfully"
    else
        log_error "Failed to delete cluster"
        return 1
    fi
}

main() {
    log_step "Cleanup KServe Argo Rollout Test Environment"

    # Ask for confirmation
    log_warn "This will delete the kind cluster '$CLUSTER_NAME' and all resources"
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cleanup cancelled"
        exit 0
    fi

    # Check if cluster exists
    if cluster_exists; then
        # Set kubectl context
        kubectl config use-context "kind-${CLUSTER_NAME}" 2>/dev/null || true

        # Cleanup resources first
        cleanup_resources || log_warn "Failed to cleanup resources"
    fi

    # Delete cluster
    delete_cluster || exit 1

    log_success "Cleanup complete!"
}

main "$@"
