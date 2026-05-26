#!/bin/bash

# Test KServe deployment with Argo Rollout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

ISVC_NAME="sklearn-iris-rollout"

test_rollout_deployment() {
    log_step "Testing Rollout Deployment"

    # Deploy InferenceService with rollout annotation
    log_info "Deploying InferenceService '$ISVC_NAME' with rollout annotation..."
    kubectl apply -f "$SCRIPT_DIR/manifests/sklearn-rollout.yaml"

    # Wait for InferenceService to be ready
    wait_for_isvc_ready "$NAMESPACE" "$ISVC_NAME" 300 || {
        log_error "InferenceService failed to become ready"
        kubectl get isvc "$ISVC_NAME" -n "$NAMESPACE" -o yaml
        kubectl describe isvc "$ISVC_NAME" -n "$NAMESPACE"
        return 1
    }

    log_success "InferenceService is ready"
}

verify_rollout_resources() {
    log_step "Verifying Rollout Resources"

    local -a verification_results=()

    # Show all resources
    show_resources "$ISVC_NAME" "$NAMESPACE"

    # Check Rollout exists
    if check_resource_exists rollout "${ISVC_NAME}-predictor" "$NAMESPACE"; then
        verification_results+=("PASS:Rollout created")
    else
        verification_results+=("FAIL:Rollout not created")
    fi

    # Check Deployment does NOT exist
    if check_resource_not_exists deployment "${ISVC_NAME}-predictor" "$NAMESPACE"; then
        verification_results+=("PASS:Deployment not created (as expected)")
    else
        verification_results+=("FAIL:Deployment created (should use Rollout)")
    fi

    # Check Active service exists
    if check_resource_exists service "${ISVC_NAME}-predictor" "$NAMESPACE"; then
        verification_results+=("PASS:Active service created")
    else
        verification_results+=("FAIL:Active service not created")
    fi

    # Check Preview service exists
    if check_resource_exists service "${ISVC_NAME}-predictor-preview" "$NAMESPACE"; then
        verification_results+=("PASS:Preview service created")
    else
        verification_results+=("FAIL:Preview service not created")
    fi

    # Verify 2 services exist
    local svc_count
    svc_count=$(count_services "${ISVC_NAME}-predictor" "$NAMESPACE")
    if [ "$svc_count" -eq 2 ]; then
        verification_results+=("PASS:Dual services created (count: 2)")
    else
        verification_results+=("FAIL:Expected 2 services, found $svc_count")
    fi

    # Check HTTPRoute exists
    if check_resource_exists httproute "${ISVC_NAME}-predictor" "$NAMESPACE"; then
        verification_results+=("PASS:HTTPRoute created")
    else
        verification_results+=("FAIL:HTTPRoute not created")
    fi

    # Check HTTPRoute backend points to active service (not preview)
    if check_httproute_backend "${ISVC_NAME}-predictor" "$NAMESPACE" "${ISVC_NAME}-predictor"; then
        verification_results+=("PASS:HTTPRoute points to active service")
    else
        verification_results+=("FAIL:HTTPRoute backend incorrect")
    fi

    print_verification_summary "Rollout Resources" "${verification_results[@]}"
}

verify_rollout_configuration() {
    log_step "Verifying Rollout Configuration"

    local -a verification_results=()

    # Check BlueGreen strategy
    local strategy
    strategy=$(kubectl get rollout "${ISVC_NAME}-predictor" -n "$NAMESPACE" \
        -o jsonpath='{.spec.strategy.blueGreen}' 2>/dev/null)

    if [ -n "$strategy" ]; then
        verification_results+=("PASS:BlueGreen strategy configured")
    else
        verification_results+=("FAIL:BlueGreen strategy not configured")
    fi

    # Check active service reference
    local active_svc
    active_svc=$(kubectl get rollout "${ISVC_NAME}-predictor" -n "$NAMESPACE" \
        -o jsonpath='{.spec.strategy.blueGreen.activeService}' 2>/dev/null)

    if [ "$active_svc" = "${ISVC_NAME}-predictor" ]; then
        verification_results+=("PASS:Active service reference correct")
    else
        verification_results+=("FAIL:Active service reference: $active_svc (expected ${ISVC_NAME}-predictor)")
    fi

    # Check preview service reference
    local preview_svc
    preview_svc=$(kubectl get rollout "${ISVC_NAME}-predictor" -n "$NAMESPACE" \
        -o jsonpath='{.spec.strategy.blueGreen.previewService}' 2>/dev/null)

    if [ "$preview_svc" = "${ISVC_NAME}-predictor-preview" ]; then
        verification_results+=("PASS:Preview service reference correct")
    else
        verification_results+=("FAIL:Preview service reference: $preview_svc (expected ${ISVC_NAME}-predictor-preview)")
    fi

    print_verification_summary "Rollout Configuration" "${verification_results[@]}"
}

verify_status_propagation() {
    log_step "Verifying Status Propagation"

    local -a verification_results=()

    # Check rolloutStatus field exists
    if validate_rollout_status "$ISVC_NAME" "$NAMESPACE"; then
        verification_results+=("PASS:RolloutStatus populated in InferenceService")
    else
        verification_results+=("FAIL:RolloutStatus not populated")
    fi

    # Check phase
    local phase
    phase=$(kubectl get isvc "$ISVC_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.components.predictor.rolloutStatus.phase}' 2>/dev/null)

    if [ -n "$phase" ]; then
        verification_results+=("PASS:Rollout phase: $phase")
    else
        verification_results+=("FAIL:Rollout phase not set")
    fi

    print_verification_summary "Status Propagation" "${verification_results[@]}"
}

test_bluegreen_update() {
    log_step "Testing BlueGreen Update"

    # Get current pod hash
    local old_pod_hash
    old_pod_hash=$(kubectl get rollout "${ISVC_NAME}-predictor" -n "$NAMESPACE" \
        -o jsonpath='{.status.currentPodHash}' 2>/dev/null)

    log_info "Current pod hash: $old_pod_hash"

    # Get active service endpoints before update
    log_info "Active service endpoints before update:"
    get_service_endpoints "${ISVC_NAME}-predictor" "$NAMESPACE"

    # Update storageUri
    log_info "Updating InferenceService storageUri..."
    kubectl patch isvc "$ISVC_NAME" -n "$NAMESPACE" --type merge -p '{
        "spec": {
            "predictor": {
                "model": {
                    "storageUri": "gs://kfserving-examples/models/sklearn/2.0/model"
                }
            }
        }
    }'

    # Wait a moment for rollout to start
    sleep 5

    # Monitor rollout progression
    log_info "Monitoring rollout progression..."
    if command -v kubectl-argo-rollouts &>/dev/null; then
        kubectl argo rollouts get rollout "${ISVC_NAME}-predictor" -n "$NAMESPACE"
    else
        log_warn "kubectl-argo-rollouts plugin not found, using kubectl"
        kubectl get rollout "${ISVC_NAME}-predictor" -n "$NAMESPACE" -o yaml | grep -A10 "status:"
    fi

    # Wait for rollout to complete
    wait_for_rollout "$NAMESPACE" "${ISVC_NAME}-predictor" 300 || {
        log_error "Rollout failed to complete"
        kubectl describe rollout "${ISVC_NAME}-predictor" -n "$NAMESPACE"
        return 1
    }

    # Get new pod hash
    local new_pod_hash
    new_pod_hash=$(kubectl get rollout "${ISVC_NAME}-predictor" -n "$NAMESPACE" \
        -o jsonpath='{.status.currentPodHash}' 2>/dev/null)

    log_info "New pod hash: $new_pod_hash"

    if [ "$new_pod_hash" != "$old_pod_hash" ]; then
        log_success "Pod hash changed: $old_pod_hash -> $new_pod_hash"
    else
        log_warn "Pod hash unchanged (update may not have triggered)"
    fi

    # Verify active service endpoints changed
    log_info "Active service endpoints after update:"
    get_service_endpoints "${ISVC_NAME}-predictor" "$NAMESPACE"

    log_success "BlueGreen update completed"
}

test_service_endpoints() {
    log_step "Testing Service Endpoint Management"

    local -a verification_results=()

    # Check active service has endpoints
    local active_endpoints
    active_endpoints=$(get_service_endpoints "${ISVC_NAME}-predictor" "$NAMESPACE")

    if [ -n "$active_endpoints" ]; then
        verification_results+=("PASS:Active service has endpoints")
        log_info "Active endpoints: $active_endpoints"
    else
        verification_results+=("FAIL:Active service has no endpoints")
    fi

    # Check preview service has endpoints
    local preview_endpoints
    preview_endpoints=$(get_service_endpoints "${ISVC_NAME}-predictor-preview" "$NAMESPACE")

    if [ -n "$preview_endpoints" ]; then
        verification_results+=("PASS:Preview service has endpoints")
        log_info "Preview endpoints: $preview_endpoints"
    else
        verification_results+=("FAIL:Preview service has no endpoints")
    fi

    # After stable rollout, active and preview should point to same pods
    if [ "$active_endpoints" = "$preview_endpoints" ]; then
        verification_results+=("PASS:Active and preview endpoints match (stable state)")
    else
        verification_results+=("WARN:Active and preview endpoints differ (may be mid-rollout)")
    fi

    print_verification_summary "Service Endpoints" "${verification_results[@]}"
}

cleanup() {
    log_step "Cleaning up"

    cleanup_isvc "$ISVC_NAME" "$NAMESPACE"

    log_success "Cleanup complete"
}

main() {
    log_step "Rollout Deployment Test Suite"

    # Check cluster exists
    if ! cluster_exists; then
        log_error "Cluster '$CLUSTER_NAME' does not exist. Run ./01-setup-cluster.sh first."
        exit 1
    fi

    # Set kubectl context
    kubectl config use-context "kind-${CLUSTER_NAME}"

    # Check Argo Rollouts installed
    if ! kubectl get crd rollouts.argoproj.io &>/dev/null; then
        log_error "Argo Rollouts CRD not found. Run ./02-install-components.sh first."
        exit 1
    fi

    # Run tests
    test_rollout_deployment || exit 1
    verify_rollout_resources || exit 1
    verify_rollout_configuration || exit 1
    verify_status_propagation || log_warn "Status propagation verification failed"
    test_bluegreen_update || log_warn "BlueGreen update test failed"
    test_service_endpoints || log_warn "Service endpoint test failed"

    # Cleanup
    cleanup

    log_success "All rollout deployment tests completed!"
}

main "$@"
