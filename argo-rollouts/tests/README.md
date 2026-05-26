# KServe Argo Rollout Test Environment

Automated testing scripts for validating KServe Argo Rollout integration in a local kind cluster with Gateway API support.

## Overview

This test suite sets up a complete KServe environment with:
- KServe controller with Standard (raw) deployment mode
- Gateway API (Envoy Gateway) for routing
- Argo Rollouts for progressive delivery (future)
- Complete KServe ConfigMap configuration

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    kind Cluster                              │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Gateway API (Envoy Gateway)                          │  │
│  │  - GatewayClass: envoy-gateway                        │  │
│  │  - Gateway: kserve-gateway                            │  │
│  └────────────────┬─────────────────────────────────────┘  │
│                   │ Routes traffic via HTTPRoute            │
│  ┌────────────────▼─────────────────────────────────────┐  │
│  │  KServe InferenceService                              │  │
│  │  - Deployment Mode: Standard (raw Kubernetes)         │  │
│  │  - Optional: Argo Rollout (BlueGreen/Canary)         │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  KServe Controllers                                   │  │
│  │  - kserve-controller-manager                          │  │
│  │  - llmisvc-controller-manager                         │  │
│  │  - kserve-localmodel-controller-manager              │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Supporting Components                                │  │
│  │  - cert-manager (webhook certificates)                │  │
│  │  - Argo Rollouts controller                           │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Required Tools
- `kind` (v0.20.0+)
- `kubectl` (v1.28+)
- `docker`
- `curl`, `jq`

### Optional Tools
- `kubectl-argo-rollouts` plugin (for rollout monitoring)

```bash
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-$(uname -s | tr '[:upper:]' '[:lower:]')-amd64
chmod +x kubectl-argo-rollouts-*
sudo mv kubectl-argo-rollouts-* /usr/local/bin/kubectl-argo-rollouts
```

## Quick Start

### 1. Setup Cluster
```bash
./01-setup-cluster.sh
```

Creates a kind cluster with Gateway API support and port mappings.

### 2. Install Components
```bash
./02-install-components.sh
```

Installs and configures:
- Gateway API CRDs (v1.0.0)
- Envoy Gateway (lightweight Gateway API implementation)
- Argo Rollouts controller and CRDs
- cert-manager (for webhook certificates)
- KServe CRDs and ConfigMap with complete configuration
- KServe controllers (kserve-controller-manager, llmisvc-controller-manager, localmodel-controller-manager)
- Serving runtimes (sklearn, etc.)
- GatewayClass and Gateway resources

**What it does:**
- Builds KServe controller image if not present
- Loads controller images into kind cluster
- Creates webhook certificates using cert-manager
- Deploys all KServe controllers with proper image pull policies
- Patches deployments to use local images (`imagePullPolicy: IfNotPresent`)
- Creates complete `inferenceservice-config` ConfigMap including:
  - `deploy.defaultDeploymentMode: "Standard"`
  - `ingress.enableGatewayApi: true`
  - Resource configurations (storageInitializer, logger, batcher, agent, router)
- Verifies all components are ready

### 3. Test Standard Deployment
```bash
./03-test-standard-deployment.sh
```

Tests standard deployment (without Rollout):
- InferenceService without rollout annotation
- Deployment resource created (not Rollout)
- Single service created (no preview service)
- HTTPRoute configuration
- Standard rolling update

### 4. Test Rollout Deployment (Future)
```bash
./04-test-rollout-deployment.sh
```

Tests Rollout deployment (requires implementation):
- InferenceService with rollout annotation
- Rollout resource created (not Deployment)
- Dual services created (active + preview)
- BlueGreen strategy configuration
- Status propagation

### 5. Cleanup
```bash
./99-cleanup.sh
```

## Components

### Core Infrastructure
- **kind** - Kubernetes IN Docker (local cluster)
- **Gateway API CRDs** - Kubernetes networking API (v1.0.0)
- **Envoy Gateway** - Lightweight Gateway API implementation
- **cert-manager** - Certificate management for webhooks

### KServe Components
- **KServe CRDs** - InferenceService, ClusterServingRuntime, etc.
- **KServe Controllers** - Main controller, LLMInferenceService controller, LocalModel controller
- **Serving Runtimes** - sklearn, pytorch, tensorflow, etc.

### Progressive Delivery
- **Argo Rollouts** - Advanced deployment strategies (BlueGreen, Canary)

## Scripts

### common.sh
Common functions and utilities:
- Logging (info, success, warn, error)
- Cluster helpers (cluster_exists, wait_for_cluster_ready)
- Resource helpers (wait_for_pod, wait_for_deployment, wait_for_rollout, wait_for_isvc_ready)
- Verification helpers (check_resource_exists, check_resource_not_exists)
- Inference testing (test_inference)
- Cleanup helpers (cleanup_isvc)

### 01-setup-cluster.sh
Creates kind cluster with configuration from `manifests/kind-cluster-config.yaml`.

**Environment Variables:**
- `CLUSTER_NAME`: Cluster name (default: `kserve-rollout-test`)
- `NAMESPACE`: Kubernetes namespace (default: `default`)

### 02-install-components.sh
Installs all required components for testing.

**Environment Variables:**
- `GATEWAY_API_VERSION`: Gateway API version (default: `v1.0.0`)
- `ENVOY_GATEWAY_VERSION`: Envoy Gateway version (default: `latest`)
- `ARGO_ROLLOUTS_VERSION`: Argo Rollouts version (default: `latest`)

**Important Notes:**
- Uses `--server-side --force-conflicts` for KServe CRD installation to avoid annotation size limits
- Creates GatewayClass resource (required for Gateway to function)
- Gateway may show "Programmed: False" in kind (normal - no external IP assigned)
- The important check is that Gateway is "Accepted" and listener is "Programmed"

### 03-test-standard-deployment.sh
Tests standard deployment (without Rollout).

### 04-test-rollout-deployment.sh
Tests Rollout deployment (not yet implemented).

### 99-cleanup.sh
Cleanup script with confirmation prompt.

## Manifests

All YAML manifests are in `manifests/` directory:

### kind-cluster-config.yaml
Kind cluster configuration with port mappings.

### gatewayclass.yaml
Envoy GatewayClass resource (required for Gateway).

### gateway.yaml
Gateway API Gateway resource:
- Name: kserve-gateway
- Namespace: envoy-gateway-system
- GatewayClass: envoy-gateway
- Listener on port 80 for HTTP

### inferenceservice-config.yaml
KServe ConfigMap with complete configuration:

**Required sections:**
1. **deploy** - Deployment mode configuration
   ```yaml
   deploy: |
     {
       "defaultDeploymentMode": "Standard"
     }
   ```

2. **ingress** - Gateway API and routing configuration
   ```yaml
   ingress: |
     {
       "enableGatewayApi": true,
       "kserveIngressGateway": "envoy-gateway-system/kserve-gateway",
       "ingressDomain": "example.com",
       "domainTemplate": "{{ .Name }}-{{ .Namespace }}.{{ .IngressDomain }}",
       "urlScheme": "http"
     }
   ```

3. **storageInitializer** - Model download container configuration
4. **logger** - Logging sidecar configuration
5. **batcher** - Request batching configuration
6. **agent** - Agent sidecar configuration
7. **router** - Router (for InferenceGraph) configuration

### sklearn-standard.yaml
InferenceService manifest for standard deployment:
- Deployment mode: Standard (via annotation)
- Model: sklearn iris classifier
- Storage: gs://kfserving-examples/models/sklearn/1.0/model

### sklearn-rollout.yaml
InferenceService manifest for Argo Rollout deployment:
- Deployment mode: ArgoRollout (via annotation)
- Uses Argo Rollout instead of Kubernetes Deployment
- ⚠️ Requires Rollout support implementation in KServe

### inference-payload.json
Test inference request payload.

## Configuration

### Deployment Modes

KServe supports three deployment modes:

1. **Serverless (Knative)** - Default mode, requires Knative Serving
   - Auto-scaling to zero
   - Revision-based deployments
   - Uses Knative Gateway for routing

2. **Standard (RawDeployment)** - Raw Kubernetes mode
   - Standard Kubernetes Deployments
   - HPA/KEDA for autoscaling
   - Uses Gateway API or Ingress for routing

3. **ArgoRollout** - Advanced deployment mode (planned)
   - Argo Rollout resources (BlueGreen/Canary strategies)
   - HPA/KEDA for autoscaling
   - Uses Gateway API for traffic management
   - ⚠️ Requires implementation - not yet available

This test environment uses **Standard mode** with **Gateway API**. Rollout support is planned but not yet implemented.

### Gateway API

Gateway API is enabled via ConfigMap. This creates:
- HTTPRoute for each InferenceService
- Routes traffic based on Host header
- Example: `sklearn-iris-default.example.com`

## Testing and Verification

### End-to-End Test

```bash
# 1. Create InferenceService
kubectl apply -f manifests/sklearn-standard.yaml

# 2. Wait for ready
kubectl wait --for=condition=Ready isvc/sklearn-iris -n default --timeout=300s

# 3. Check HTTPRoute created
kubectl get httproute -n default
# Expected: sklearn-iris and sklearn-iris-predictor routes

# 4. Check InferenceService status
kubectl get isvc sklearn-iris -n default
# Expected: READY = True

# 5. Port-forward Gateway
kubectl port-forward -n envoy-gateway-system \
    service/envoy-envoy-gateway-system-kserve-gateway-2afb1d41 8080:80 &

# 6. Make inference request
curl -H "Host: sklearn-iris-default.example.com" \
     -H "Content-Type: application/json" \
     http://localhost:8080/v1/models/sklearn-iris:predict \
     -d '{"instances": [[6.8, 2.8, 4.8, 1.4], [6.0, 3.4, 4.5, 1.6]]}'

# Expected response:
# {"predictions": [1, 1]}
```

### Verification Checklist

#### After 02-install-components.sh
- [ ] Gateway API CRDs installed
- [ ] Envoy Gateway deployed and ready
- [ ] Argo Rollouts deployed and ready
- [ ] Rollout CRD available
- [ ] cert-manager deployed and ready
- [ ] KServe CRDs installed
- [ ] KServe controllers deployed and ready (kserve-controller-manager, llmisvc-controller-manager, localmodel-controller-manager)
- [ ] Serving runtimes installed (sklearn, etc.)
- [ ] GatewayClass created and accepted
- [ ] Gateway resource created and accepted
- [ ] Gateway listener programmed
- [ ] inferenceservice-config ConfigMap has complete configuration

#### After 03-test-standard-deployment.sh
- [ ] Deployment created
- [ ] Rollout NOT created
- [ ] Single service created
- [ ] Preview service NOT created
- [ ] HTTPRoute created
- [ ] HTTPRoute points to active service
- [ ] InferenceService Ready=True
- [ ] Inference request succeeds

## Troubleshooting

### Common Issues and Solutions

#### 1. Controller Image Pull Failures

**Problem:**
- `kserve-controller-manager` and `llmisvc-controller-manager` pods stuck in `ImagePullBackOff`
- Trying to pull images from DockerHub instead of using local images

**Symptoms:**
```bash
$ kubectl get pods -n kserve
NAME                                         READY   STATUS             RESTARTS   AGE
kserve-controller-manager-xxx                1/2     ImagePullBackOff   0          2m
```

**Root Cause:**
- Default `imagePullPolicy: Always` causes Kubernetes to always pull from registry
- In kind clusters, images are preloaded locally and should not be pulled externally

**Solution:**
The script automatically patches deployments to use `imagePullPolicy: IfNotPresent`:

```bash
kubectl patch deployment kserve-controller-manager -n kserve --type='json' \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "IfNotPresent"}]'

kubectl patch deployment llmisvc-controller-manager -n kserve --type='json' \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "IfNotPresent"}]'
```

**Location in Script:** `02-install-components.sh:198-203`

#### 2. Missing StorageInitializer Configuration

**Problem:**
- InferenceService reconciliation fails with resource parsing errors

**Symptoms:**
```
Failed to parse resource configuration for "storageInitializer"."memoryRequest":
quantities must match the regular expression '^([+-]?[0-9.]+)([eEinumkKMGTP]*[-+]?[0-9]*)$'
```

**Root Cause:**
- The `inferenceservice-config` ConfigMap is missing the `storageInitializer` section
- KServe defaults to invalid values when config section is missing

**Solution:**
Ensure ConfigMap includes complete `storageInitializer` configuration:

```yaml
storageInitializer: |
  {
    "image": "kserve/storage-initializer:latest",
    "memoryRequest": "100Mi",
    "memoryLimit": "1Gi",
    "cpuRequest": "100m",
    "cpuLimit": "1",
    "caBundleConfigMapName": "",
    "caBundleVolumeMountPath": "/etc/ssl/custom-certs",
    "enableModelcar": true,
    "cpuModelcar": "10m",
    "memoryModelcar": "15Mi",
    "uidModelcar": 1010
  }
```

**Location:** `manifests/inferenceservice-config.yaml:20-33`

#### 3. Missing Logger Configuration

**Problem:**
- Pod mutation webhook fails with resource parsing errors

**Symptoms:**
```
Failed to parse resource configuration for "logger":
quantities must match the regular expression '^([+-]?[0-9.]+)([eEinumkKMGTP]*[-+]?[0-9]*)$'
```

**Root Cause:**
- ConfigMap is missing the `logger` section
- Webhook tries to inject logger sidecar but fails due to invalid default config

**Solution:**
Ensure ConfigMap includes `logger`, `batcher`, `agent`, and `router` configurations with valid Kubernetes resource quantities (e.g., "100Mi", "1Gi", "100m", "1").

**Location:** `manifests/inferenceservice-config.yaml:34-69`

#### 4. HTTPRoute Not Created

**Problem:**
- InferenceService creates Ingress resources instead of HTTPRoutes
- Controller logs show no HTTPRoute-related messages

**Symptoms:**
```bash
$ kubectl get httproute -n default
No resources found in default namespace.

$ kubectl get ingress -n default
NAME           CLASS   HOSTS                              ADDRESS   PORTS   AGE
sklearn-iris   istio   sklearn-iris-default.example.com             80      1m
```

**Root Cause:**
- ConfigMap has `enableGatewayApi: true` but controller needs restart to pick up changes
- Resource parsing errors (issues #2 and #3) prevent controller from functioning

**Solution:**
1. Fix all ConfigMap resource parsing errors
2. Restart controller to reload configuration:
   ```bash
   kubectl delete pod -n kserve -l control-plane=kserve-controller-manager
   ```

**Verification:**
After fixes, controller logs should show:
```
{"logger":"IngressReconciler","msg":"Creating Predictor HttpRoute resource","name":"sklearn-iris-predictor"}
{"logger":"IngressReconciler","msg":"Creating top level HttpRoute resource","name":"sklearn-iris"}
```

### Quick Diagnostic Commands

```bash
# Check all KServe pods
kubectl get pods -n kserve

# Expected: All pods should be Running
# - kserve-controller-manager: 2/2 Running
# - llmisvc-controller-manager: 1/1 Running
# - kserve-localmodel-controller-manager: 1/1 Running

# Check controller logs
kubectl logs -n kserve deployment/kserve-controller-manager -c manager --tail=50

# Check for errors
kubectl logs -n kserve deployment/kserve-controller-manager -c manager | grep -i error

# Check InferenceService status
kubectl get isvc -n default
kubectl describe isvc sklearn-iris -n default

# Check HTTPRoutes are created (Gateway API enabled)
kubectl get httproute -n default

# Check Gateway status
kubectl get gateway kserve-gateway -n envoy-gateway-system -o yaml

# Check ConfigMap configuration
kubectl get configmap inferenceservice-config -n kserve -o yaml
```

### Cluster Issues

```bash
# Check kind version
kind version

# Check Docker is running
docker ps

# Delete and recreate cluster
kind delete cluster --name kserve-rollout-test
./01-setup-cluster.sh
```

### Rollout Issues

```bash
# Check if Argo Rollouts CRD exists
kubectl get crd rollouts.argoproj.io

# Check Argo Rollouts controller
kubectl get pods -n argo-rollouts

# Check annotation on InferenceService
kubectl get isvc <name> -o yaml | grep enable-rollout
```

## Debugging Commands

### Cluster Info
```bash
kubectl cluster-info
kubectl get nodes
kubectl get pods -A
```

### Rollout Info
```bash
# Get rollout status
kubectl argo rollouts get rollout <name>

# Watch rollout progression
kubectl argo rollouts get rollout <name> --watch

# Describe rollout
kubectl describe rollout <name>
```

### Service Info
```bash
# Check service endpoints
kubectl get endpoints <service-name>

# Check service configuration
kubectl get svc <service-name> -o yaml
```

### HTTPRoute Info
```bash
# Check HTTPRoute configuration
kubectl get httproute <name> -o yaml

# Check HTTPRoute status
kubectl get httproute <name> -o jsonpath='{.status.parents[0]}' | jq .

# Check Gateway status
kubectl get gateway -A
```

### InferenceService Info
```bash
# Get InferenceService status
kubectl get isvc <name> -o yaml

# Check rollout status (future)
kubectl get isvc <name> -o jsonpath='{.status.components.predictor.rolloutStatus}'
```

## Environment Variables

Global configuration via environment variables:

```bash
export CLUSTER_NAME="my-test-cluster"
export NAMESPACE="my-namespace"
export TIMEOUT=600  # Timeout in seconds
export GATEWAY_API_VERSION="v1.0.0"
export ENVOY_GATEWAY_VERSION="latest"
export ARGO_ROLLOUTS_VERSION="latest"
```

## Notes and Key Learnings

### KServe Controller Deployment
The `02-install-components.sh` script fully deploys all KServe controllers:
- Builds KServe controller image if not present
- Loads images into kind cluster
- Creates webhook certificates via cert-manager
- Deploys all controllers with proper configuration
- Patches deployments for local image usage

### Gateway API Configuration
The setup configures KServe to use Gateway API for routing:
- `enableGatewayApi: true` in ConfigMap
- HTTPRoutes created instead of Ingress resources
- Routes traffic through Envoy Gateway
- Two HTTPRoutes created per InferenceService:
  - Top-level route for the InferenceService
  - Component route for the predictor

### Key Learnings

1. **imagePullPolicy in kind** - Always set to `IfNotPresent` for locally loaded images in kind clusters

2. **Complete ConfigMap Required** - All resource configuration sections must be present with valid Kubernetes resource quantity formats:
   - Memory: "100Mi", "1Gi", "2Gi"
   - CPU: "100m", "1", "2"

3. **Controller Restart** - Configuration changes in ConfigMap require controller pod restart to take effect

4. **Gateway API Enablement** - Requires both:
   - `enableGatewayApi: true` in ConfigMap
   - Proper Gateway infrastructure (GatewayClass, Gateway resources)

5. **Resource Validation** - KServe validates resource specifications using Kubernetes regex patterns. Invalid formats cause reconciliation failures.

### Inference Testing
All inference tests should work with the deployed KServe controllers. The complete ConfigMap configuration ensures proper resource specifications for all components.

### Multi-Node Testing
Multi-node Ray serving tests are out of scope for this test suite. See implementation plan for future multi-node test scenarios with Rollouts.

### Argo Rollout Support
Rollout support in KServe controller is not yet implemented. The `04-test-rollout-deployment.sh` test will not work until the Rollout reconciler is added to KServe. See the implementation plan at `/Users/rvig/.claude/plans/logical-leaping-lovelace.md` for details.

## Test Flow

```
01-setup-cluster.sh
    ↓
02-install-components.sh
    ↓
03-test-standard-deployment.sh
    ↓
04-test-rollout-deployment.sh (future)
    ↓
99-cleanup.sh (optional)
```

## Directory Structure

```
tests/
├── README.md                          # This file
├── common.sh                          # Shared utility functions
├── 01-setup-cluster.sh               # Cluster creation script
├── 02-install-components.sh          # Component installation script
├── 03-test-standard-deployment.sh    # Standard deployment test
├── 04-test-rollout-deployment.sh     # Rollout deployment test (future)
├── 99-cleanup.sh                     # Cleanup script
└── manifests/
    ├── kind-cluster-config.yaml      # Kind cluster configuration
    ├── gatewayclass.yaml             # GatewayClass resource
    ├── gateway.yaml                  # Gateway resource
    ├── inferenceservice-config.yaml  # KServe controller config
    ├── sklearn-standard.yaml         # Test InferenceService (standard)
    ├── sklearn-rollout.yaml          # Test InferenceService (rollout)
    └── inference-payload.json        # Test inference request
```

## References

- **KServe Documentation**: https://kserve.github.io/website/
- **KServe ConfigMap Documentation**: https://kserve.github.io/website/latest/admin/serverless/serverless/
- **Gateway API Documentation**: https://gateway-api.sigs.k8s.io/
- **Envoy Gateway Documentation**: https://gateway.envoyproxy.io/
- **Argo Rollouts Documentation**: https://argoproj.github.io/rollouts/
- **kind Documentation**: https://kind.sigs.k8s.io/
- **kind Local Registry**: https://kind.sigs.k8s.io/docs/user/local-registry/
- **Implementation Plan**: `/Users/rvig/.claude/plans/logical-leaping-lovelace.md`
