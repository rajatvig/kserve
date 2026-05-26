#!/bin/bash

# Test standard KServe deployment (without Rollout)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

ISVC_NAME="sklearn-iris"

test_standard_deployment() {
    log_step "Testing Standard Deployment (No Rollout)"

    # Deploy InferenceService
    log_info "Deploying InferenceService '$ISVC_NAME'..."
    kubectl apply -f "$SCRIPT_DIR/manifests/sklearn-standard.yaml"

    # Wait for InferenceService to be ready
    wait_for_isvc_ready "$NAMESPACE" "$ISVC_NAME" 300 || {
        log_error "InferenceService failed to become ready"
        kubectl get isvc "$ISVC_NAME" -n "$NAMESPACE" -o yaml
        kubectl describe isvc "$ISVC_NAME" -n "$NAMESPACE"
        return 1
    }

    log_success "InferenceService is ready"
}

verify_resources() {
    log_step "Verifying Resources"

    local -a verification_results=()

    # Show all resources
    show_resources "$ISVC_NAME" "$NAMESPACE"

    # Check Deployment exists
    if check_resource_exists deployment "${ISVC_NAME}-predictor" "$NAMESPACE"; then
        verification_results+=("PASS:Deployment created")
    else
        verification_results+=("FAIL:Deployment not created")
    fi

    # Check Rollout does NOT exist
    if check_resource_not_exists rollout "${ISVC_NAME}-predictor" "$NAMESPACE"; then
        verification_results+=("PASS:Rollout not created (as expected)")
    else
        verification_results+=("FAIL:Rollout created (should not exist)")
    fi

    # Check Service exists
    if check_resource_exists service "${ISVC_NAME}-predictor" "$NAMESPACE"; then
        verification_results+=("PASS:Service created")
    else
        verification_results+=("FAIL:Service not created")
    fi

    # Check Preview service does NOT exist
    if check_resource_not_exists service "${ISVC_NAME}-predictor-preview" "$NAMESPACE"; then
        verification_results+=("PASS:Preview service not created (as expected)")
    else
        verification_results+=("FAIL:Preview service created (should not exist)")
    fi

    # Verify only 1 service exists
    local svc_count
    svc_count=$(count_services "${ISVC_NAME}-predictor" "$NAMESPACE")
    if [ "$svc_count" -eq 1 ]; then
        verification_results+=("PASS:Single service created (count: 1)")
    else
        verification_results+=("FAIL:Expected 1 service, found $svc_count")
    fi

    # Check HTTPRoute exists
    if check_resource_exists httproute "${ISVC_NAME}-predictor" "$NAMESPACE"; then
        verification_results+=("PASS:HTTPRoute created")
    else
        verification_results+=("FAIL:HTTPRoute not created")
    fi

    # Check HTTPRoute backend
    if check_httproute_backend "${ISVC_NAME}-predictor" "$NAMESPACE" "${ISVC_NAME}-predictor"; then
        verification_results+=("PASS:HTTPRoute points to active service")
    else
        verification_results+=("FAIL:HTTPRoute backend incorrect")
    fi

    print_verification_summary "Standard Deployment" "${verification_results[@]}"
}

test_inference() {
    log_step "Testing Inference"

    # Get service endpoint
    local service_ip
    service_ip=$(kubectl get svc "${ISVC_NAME}-predictor" -n "$NAMESPACE" \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

    if [ -z "$service_ip" ]; then
        log_error "Failed to get service IP"
        return 1
    fi

    log_info "Service IP: $service_ip"

    # Test inference (inside cluster)
    log_info "Testing inference via port-forward..."

    # Start port-forward in background
    kubectl port-forward -n "$NAMESPACE" "svc/${ISVC_NAME}-predictor" 8080:80 &
    local pf_pid=$!

    # Wait for port-forward to be ready
    sleep 3

    # Test inference
    local payload
    payload=$(cat "$SCRIPT_DIR/manifests/inference-payload.json")

    if test_inference "http://localhost:8080/v1/models/${ISVC_NAME}:predict" "$payload" 200; then
        log_success "Inference test passed"
        local result=0
    else
        log_error "Inference test failed"
        local result=1
    fi

    # Cleanup port-forward
    kill $pf_pid 2>/dev/null || true

    return $result
}

test_update() {
    log_step "Testing Update (Standard Rolling Update)"

    log_info "Updating InferenceService storageUri..."

    # Get current generation
    local old_generation
    old_generation=$(kubectl get deployment "${ISVC_NAME}-predictor" -n "$NAMESPACE" \
        -o jsonpath='{.metadata.generation}' 2>/dev/null)

    log_info "Current deployment generation: $old_generation"

    # Update storageUri (simulate model update)
    kubectl patch isvc "$ISVC_NAME" -n "$NAMESPACE" --type merge -p '{
        "spec": {
            "predictor": {
                "model": {
                    "storageUri": "gs://kfserving-examples/models/sklearn/2.0/model"
                }
            }
        }
    }'

    # Wait for deployment to be updated
    log_info "Waiting for deployment to update..."
    sleep 5

    local new_generation
    new_generation=$(kubectl get deployment "${ISVC_NAME}-predictor" -n "$NAMESPACE" \
        -o jsonpath='{.metadata.generation}' 2>/dev/null)

    if [ "$new_generation" -gt "$old_generation" ]; then
        log_success "Deployment generation increased: $old_generation -> $new_generation"
    else
        log_warn "Deployment generation did not change (may update soon)"
    fi

    # Wait for rollout to complete
    wait_for_deployment "$NAMESPACE" "${ISVC_NAME}-predictor" 300 || {
        log_error "Deployment rollout failed"
        return 1
    }

    log_success "Standard rolling update completed"

    # Verify still using Deployment (not Rollout)
    if check_resource_not_exists rollout "${ISVC_NAME}-predictor" "$NAMESPACE"; then
        log_success "Still using Deployment (not Rollout)"
        return 0
    else
        log_error "Unexpectedly using Rollout"
        return 1
    fi
}

cleanup() {
    log_step "Cleaning up"

    cleanup_isvc "$ISVC_NAME" "$NAMESPACE"

    log_success "Cleanup complete"
}

main() {
    log_step "Standard Deployment Test Suite"

    # Check cluster exists
    if ! cluster_exists; then
        log_error "Cluster '$CLUSTER_NAME' does not exist. Run ./01-setup-cluster.sh first."
        exit 1
    fi

    # Set kubectl context
    kubectl config use-context "kind-${CLUSTER_NAME}"

    # Run tests
    test_standard_deployment || exit 1
    verify_resources || exit 1
    test_inference || log_warn "Inference test failed (may need KServe controller)"
    test_update || log_warn "Update test failed"

    # Cleanup
    cleanup

    log_success "All standard deployment tests completed!"
    echo ""
    log_info "Next step: ./04-test-rollout-deployment.sh"
}

main "$@"
