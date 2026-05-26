#!/bin/bash

# Setup kind cluster for KServe Argo Rollout testing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

main() {
    log_step "Setting up kind cluster for KServe Argo Rollout testing"

    # Check required commands
    check_required_commands || exit 1

    # Check if cluster already exists
    if cluster_exists; then
        log_warn "Cluster '$CLUSTER_NAME' already exists"
        read -p "Delete and recreate? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Deleting existing cluster..."
            kind delete cluster --name "$CLUSTER_NAME"
        else
            log_info "Using existing cluster"
            wait_for_cluster_ready || exit 1
            log_success "Cluster setup complete"
            return 0
        fi
    fi

    # Create cluster
    log_info "Creating kind cluster '$CLUSTER_NAME'..."
    local cluster_config="$SCRIPT_DIR/manifests/kind-cluster-config.yaml"

    if [ ! -f "$cluster_config" ]; then
        log_error "Cluster config not found: $cluster_config"
        exit 1
    fi

    if ! kind create cluster --config "$cluster_config" --wait 60s; then
        log_error "Failed to create kind cluster"
        exit 1
    fi

    # Wait for cluster to be ready
    wait_for_cluster_ready || exit 1

    # Verify cluster
    log_info "Verifying cluster..."
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"

    # Check nodes
    log_info "Cluster nodes:"
    kubectl get nodes

    # Create default namespace if needed (usually exists)
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - || true

    log_success "Cluster setup complete!"
    echo ""
    log_info "Cluster name: $CLUSTER_NAME"
    log_info "Context: kind-$CLUSTER_NAME"
    log_info "Namespace: $NAMESPACE"
    echo ""
    log_info "Next step: Run ./02-install-components.sh"
}

main "$@"
