#!/bin/bash

# Install required components for KServe Argo Rollout testing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.0.0}"
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-latest}"
ARGO_ROLLOUTS_VERSION="${ARGO_ROLLOUTS_VERSION:-latest}"
GATEWAY_API_PLUGIN_VERSION="${GATEWAY_API_PLUGIN_VERSION:-v0.10.0}"

install_gateway_api() {
    log_step "Installing Gateway API CRDs"

    log_info "Installing Gateway API $GATEWAY_API_VERSION..."
    if ! kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"; then
        log_error "Failed to install Gateway API CRDs"
        return 1
    fi

    log_info "Waiting for Gateway API CRDs to be established..."
    kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=60s
    kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=60s

    log_success "Gateway API CRDs installed"
}

install_envoy_gateway() {
    log_step "Installing Envoy Gateway"

    log_info "Installing Envoy Gateway..."
    # Note: May show annotation warnings, this is expected
    if ! kubectl apply -f "https://github.com/envoyproxy/gateway/releases/${ENVOY_GATEWAY_VERSION}/download/install.yaml" 2>&1 | grep -v "unrecognized format"; then
        log_warn "Some warnings occurred during Envoy Gateway installation (may be normal)"
    fi

    log_info "Waiting for Envoy Gateway to be ready..."
    # Use correct label selector
    kubectl wait --for=condition=Ready pod -l control-plane=envoy-gateway -n envoy-gateway-system --timeout=300s || {
        log_error "Envoy Gateway failed to become ready"
        kubectl get pods -n envoy-gateway-system
        return 1
    }

    log_success "Envoy Gateway installed and ready"
}

install_argo_rollouts() {
    log_step "Installing Argo Rollouts"

    # Create namespace
    log_info "Creating argo-rollouts namespace..."
    kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -

    # Install Argo Rollouts
    log_info "Installing Argo Rollouts..."
    if ! kubectl apply -n argo-rollouts -f "https://github.com/argoproj/argo-rollouts/releases/${ARGO_ROLLOUTS_VERSION}/download/install.yaml"; then
        log_error "Failed to install Argo Rollouts"
        return 1
    fi

    log_info "Waiting for Argo Rollouts controller to be ready..."
    wait_for_deployment argo-rollouts argo-rollouts 300 || {
        log_error "Argo Rollouts controller failed to become ready"
        kubectl get pods -n argo-rollouts
        return 1
    }

    # Verify Rollout CRD
    log_info "Verifying Rollout CRD..."
    if kubectl get crd rollouts.argoproj.io &>/dev/null; then
        log_success "Rollout CRD is available"
    else
        log_error "Rollout CRD not found"
        return 1
    fi

    log_success "Argo Rollouts installed and ready"
}

install_gateway_api_plugin() {
    log_step "Installing Argo Rollouts Gateway API Plugin"

    # Install RBAC for Gateway API plugin
    log_info "Creating RBAC for Gateway API plugin..."
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gateway-controller-role
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes"]
    verbs: ["get", "list", "watch", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gateway-admin
roleRef:
  kind: ClusterRole
  name: gateway-controller-role
  apiGroup: rbac.authorization.k8s.io
subjects:
  - kind: ServiceAccount
    name: argo-rollouts
    namespace: argo-rollouts
EOF

    if [ $? -ne 0 ]; then
        log_error "Failed to create RBAC for Gateway API plugin"
        return 1
    fi
    log_success "RBAC configured"

    # Configure plugin via ConfigMap
    log_info "Configuring Gateway API plugin (version $GATEWAY_API_PLUGIN_VERSION)..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: argo-rollouts-config
  namespace: argo-rollouts
data:
  trafficRouterPlugins: |-
    - name: "argoproj-labs/gatewayAPI"
      location: "https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/${GATEWAY_API_PLUGIN_VERSION}/gatewayapi-plugin-linux-amd64"
EOF

    if [ $? -ne 0 ]; then
        log_error "Failed to create Gateway API plugin ConfigMap"
        return 1
    fi
    log_success "Plugin ConfigMap created"

    # Restart Argo Rollouts to load the plugin
    log_info "Restarting Argo Rollouts controller to load plugin..."
    kubectl rollout restart deployment -n argo-rollouts argo-rollouts

    log_info "Waiting for Argo Rollouts to restart with plugin..."
    wait_for_deployment argo-rollouts argo-rollouts 300 || {
        log_error "Argo Rollouts failed to restart"
        kubectl get pods -n argo-rollouts
        return 1
    }

    # Verify plugin loaded
    log_info "Verifying plugin loaded..."
    sleep 5
    if kubectl logs -n argo-rollouts deployment/argo-rollouts --tail=50 | grep -q "gatewayAPI"; then
        log_success "Gateway API plugin loaded successfully"
    else
        log_warn "Could not verify plugin in logs, but installation completed"
    fi

    log_success "Gateway API plugin installed"
}

install_cert_manager() {
    log_step "Installing cert-manager"

    log_info "Installing cert-manager v1.14.2..."
    if ! kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.2/cert-manager.yaml 2>&1 | grep -v "unrecognized format"; then
        log_error "Failed to install cert-manager"
        return 1
    fi

    log_info "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s || {
        log_error "cert-manager failed to become ready"
        kubectl get pods -n cert-manager
        return 1
    }

    log_success "cert-manager installed and ready"
}

install_kserve() {
    log_step "Installing KServe"

    local kserve_dir="$SCRIPT_DIR/../.."

    # Check if we're in the kserve repo
    if [ ! -f "$kserve_dir/go.mod" ] || ! grep -q "github.com/kserve/kserve" "$kserve_dir/go.mod"; then
        log_error "Not in KServe repository. Please run this script from the kserve repo."
        return 1
    fi

    # Create kserve namespace
    log_info "Creating kserve namespace..."
    kubectl create namespace kserve --dry-run=client -o yaml | kubectl apply -f -

    # Install CRDs using server-side apply to avoid annotation size issues
    log_info "Installing KServe CRDs (using server-side apply)..."
    if ! kubectl apply -k "$kserve_dir/config/crd" --server-side --force-conflicts 2>&1 | grep -v "unrecognized format"; then
        log_error "Failed to install KServe CRDs"
        return 1
    fi

    # Wait for CRDs
    log_info "Waiting for InferenceService CRD to be established..."
    kubectl wait --for=condition=Established crd/inferenceservices.serving.kserve.io --timeout=60s

    # Create InferenceService ConfigMap with Gateway API enabled
    log_info "Creating InferenceService ConfigMap..."
    kubectl apply -f "$SCRIPT_DIR/manifests/inferenceservice-config.yaml"

    log_success "KServe CRDs and ConfigMap installed"
}

deploy_kserve_controller() {
    log_step "Deploying KServe Controller"

    local kserve_dir="$SCRIPT_DIR/../.."

    # Check if controller image exists
    if ! docker image inspect kserve/kserve-controller:latest >/dev/null 2>&1; then
        log_info "Building KServe controller image..."
        cd "$kserve_dir"
        KO_DOCKER_REPO=kserve make docker-build || {
            log_error "Failed to build KServe controller"
            return 1
        }
        cd - >/dev/null
    fi

    # Tag and load image into kind
    log_info "Loading KServe controller image into kind cluster..."
    docker tag kserve/kserve-controller:latest kserve-controller:latest
    kind load docker-image kserve-controller:latest --name "$CLUSTER_NAME"

    # Create certificates for webhooks
    log_info "Creating webhook certificates..."
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
  namespace: kserve
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: serving-cert
  namespace: kserve
spec:
  commonName: kserve-webhook-server-service.kserve.svc
  dnsNames:
    - kserve-webhook-server-service.kserve.svc
  issuerRef:
    kind: Issuer
    name: selfsigned-issuer
  secretName: kserve-webhook-server-cert
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: llmisvc-serving-cert
  namespace: kserve
spec:
  commonName: llmisvc-webhook-server-service.kserve.svc
  dnsNames:
    - llmisvc-webhook-server-service.kserve.svc
  issuerRef:
    kind: Issuer
    name: selfsigned-issuer
  secretName: llmisvc-webhook-server-cert
EOF

    # Deploy KServe controller
    log_info "Deploying KServe controller..."
    kubectl apply -k "$kserve_dir/config/default" --server-side --force-conflicts 2>&1 | grep -v "unrecognized format" | grep -v "failed calling webhook" || true

    # Patch deployments for imagePullPolicy (required for kind clusters with preloaded images)
    log_info "Patching KServe controller deployments to use local images..."
    kubectl patch deployment kserve-controller-manager -n kserve --type='json' \
        -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "IfNotPresent"}]' || true
    kubectl patch deployment llmisvc-controller-manager -n kserve --type='json' \
        -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "IfNotPresent"}]' || true

    # Wait for controller to be ready
    log_info "Waiting for KServe controller to be ready..."
    kubectl wait --for=condition=Ready pod -l control-plane=kserve-controller-manager -n kserve --timeout=120s || {
        log_error "KServe controller failed to become ready"
        kubectl get pods -n kserve
        kubectl logs -n kserve -l control-plane=kserve-controller-manager --tail=50 || true
        return 1
    }

    log_success "KServe controller deployed and ready"
}

install_serving_runtimes() {
    log_step "Installing Serving Runtimes"

    local kserve_dir="$SCRIPT_DIR/../.."

    # Install sklearn runtime
    log_info "Installing sklearn serving runtime..."
    kubectl apply -f "$kserve_dir/config/runtimes/kserve-sklearnserver.yaml"

    # Patch runtime image
    log_info "Patching sklearn runtime image..."
    kubectl patch clusterservingruntime kserve-sklearnserver --type='json' -p='[{"op": "replace", "path": "/spec/containers/0/image", "value": "kserve/sklearnserver:latest"}]'

    log_success "Serving runtimes installed"
}

create_gatewayclass() {
    log_step "Creating GatewayClass"

    log_info "Creating Envoy GatewayClass..."
    kubectl apply -f "$SCRIPT_DIR/manifests/gatewayclass.yaml"

    log_info "Waiting for GatewayClass to be accepted..."
    local max_attempts=15
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        local accepted
        accepted=$(kubectl get gatewayclass envoy-gateway \
            -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")

        if [ "$accepted" = "True" ]; then
            log_success "GatewayClass is accepted"
            return 0
        fi

        attempt=$((attempt + 1))
        log_info "Waiting for GatewayClass... (attempt $attempt/$max_attempts)"
        sleep 2
    done

    log_warn "GatewayClass may still be processing (continuing anyway)"
    return 0
}

create_gateway() {
    log_step "Creating Gateway resource"

    log_info "Creating Gateway..."
    kubectl apply -f "$SCRIPT_DIR/manifests/gateway.yaml"

    log_info "Waiting for Gateway to be accepted..."
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        local accepted
        accepted=$(kubectl get gateway kserve-gateway -n envoy-gateway-system \
            -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")

        if [ "$accepted" = "True" ]; then
            log_success "Gateway is accepted"

            # Check if listener is programmed
            local listener_programmed
            listener_programmed=$(kubectl get gateway kserve-gateway -n envoy-gateway-system \
                -o jsonpath='{.status.listeners[0].conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")

            if [ "$listener_programmed" = "True" ]; then
                log_success "Gateway listener is programmed and ready"
            else
                log_info "Gateway listener is still being configured"
            fi

            kubectl get gateway kserve-gateway -n envoy-gateway-system
            return 0
        fi

        attempt=$((attempt + 1))
        log_info "Waiting for Gateway... (attempt $attempt/$max_attempts)"
        sleep 2
    done

    log_error "Gateway failed to be accepted"
    kubectl get gateway kserve-gateway -n envoy-gateway-system -o yaml
    return 1
}

verify_installation() {
    log_step "Verifying installation"

    local -a verification_results=()

    # Check Gateway API CRDs
    if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
        verification_results+=("PASS:Gateway API CRDs installed")
    else
        verification_results+=("FAIL:Gateway API CRDs missing")
    fi

    # Check Envoy Gateway
    if kubectl get deployment envoy-gateway -n envoy-gateway-system &>/dev/null; then
        verification_results+=("PASS:Envoy Gateway deployed")
    else
        verification_results+=("FAIL:Envoy Gateway not deployed")
    fi

    # Check Argo Rollouts
    if kubectl get deployment argo-rollouts -n argo-rollouts &>/dev/null; then
        verification_results+=("PASS:Argo Rollouts deployed")
    else
        verification_results+=("FAIL:Argo Rollouts not deployed")
    fi

    # Check Rollout CRD
    if kubectl get crd rollouts.argoproj.io &>/dev/null; then
        verification_results+=("PASS:Rollout CRD available")
    else
        verification_results+=("FAIL:Rollout CRD missing")
    fi

    # Check cert-manager
    if kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
        verification_results+=("PASS:cert-manager deployed")
    else
        verification_results+=("FAIL:cert-manager not deployed")
    fi

    # Check KServe CRDs
    if kubectl get crd inferenceservices.serving.kserve.io &>/dev/null; then
        verification_results+=("PASS:InferenceService CRD available")
    else
        verification_results+=("FAIL:InferenceService CRD missing")
    fi

    # Check KServe controller
    if kubectl get deployment kserve-controller-manager -n kserve &>/dev/null; then
        verification_results+=("PASS:KServe controller deployed")
    else
        verification_results+=("FAIL:KServe controller not deployed")
    fi

    # Check sklearn runtime
    if kubectl get clusterservingruntime kserve-sklearnserver &>/dev/null; then
        verification_results+=("PASS:sklearn serving runtime available")
    else
        verification_results+=("FAIL:sklearn serving runtime missing")
    fi

    # Check GatewayClass
    if kubectl get gatewayclass envoy-gateway &>/dev/null; then
        verification_results+=("PASS:GatewayClass created")
    else
        verification_results+=("FAIL:GatewayClass missing")
    fi

    # Check Gateway resource
    if kubectl get gateway kserve-gateway -n envoy-gateway-system &>/dev/null; then
        verification_results+=("PASS:Gateway resource created")
    else
        verification_results+=("FAIL:Gateway resource missing")
    fi

    # Check Gateway is accepted
    local gw_accepted
    gw_accepted=$(kubectl get gateway kserve-gateway -n envoy-gateway-system \
        -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
    if [ "$gw_accepted" = "True" ]; then
        verification_results+=("PASS:Gateway is accepted")
    else
        verification_results+=("WARN:Gateway not yet accepted (status: $gw_accepted)")
    fi

    print_verification_summary "Component Installation" "${verification_results[@]}"
}

main() {
    log_step "Installing components for KServe Argo Rollout testing"

    # Check cluster exists
    if ! cluster_exists; then
        log_error "Cluster '$CLUSTER_NAME' does not exist. Run ./01-setup-cluster.sh first."
        exit 1
    fi

    # Set kubectl context
    kubectl config use-context "kind-${CLUSTER_NAME}"

    # Install components
    install_gateway_api || exit 1
    install_envoy_gateway || exit 1
    install_argo_rollouts || exit 1
    install_gateway_api_plugin || exit 1
    install_cert_manager || exit 1
    install_kserve || exit 1
    create_gatewayclass || exit 1
    create_gateway || exit 1
    deploy_kserve_controller || exit 1
    install_serving_runtimes || exit 1

    # Verify installation
    verify_installation || {
        log_error "Verification failed"
        exit 1
    }

    log_success "All components installed successfully!"
    echo ""
    log_info "Next step: Run tests"
    log_info "  ./03-test-standard-deployment.sh"
    log_info "  ./04-test-rollout-deployment.sh (requires Rollout implementation)"
}

main "$@"
