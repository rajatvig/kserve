# Argo Rollout Integration Investigation

**Date**: 2025-12-19
**Purpose**: Investigate how to add Argo Rollout support to KServe InferenceServices in raw deployment mode

## Executive Summary

KServe currently creates standard Kubernetes Deployments for InferenceServices in raw deployment mode. This investigation explores adding Argo Rollout support to enable advanced deployment strategies (blue-green, canary) while leveraging KServe's existing Gateway API HTTPRoute integration.

**Key Finding**: KServe's architecture is well-suited for Argo Rollout integration with minimal disruption. The existing reconciler pattern, Gateway API support, and optional feature handling provide a solid foundation.

---

## Investigation Areas

### 1. Current Raw Deployment Architecture

#### 1.1 Multi-Node Ray Architecture (CRITICAL FINDING)

**Investigation Date**: 2025-12-19
**Question**: Do worker nodes need Rollout management and service traffic routing?
**Answer**: NO - Workers only need outbound connections to head nodes.

**Evidence from codebase**:

1. **Worker-to-Head Connection Pattern**
   Location: `pkg/webhook/admission/servingruntime/servingruntime_webhook_test.go:1498,1539,1581,1623,1661`
   ```go
   Args: []string{
       "ray start --address=$RAY_HEAD_ADDRESS --block",
   },
   ```
   Workers start Ray runtime with `--address=$RAY_HEAD_ADDRESS`, meaning they connect TO the head node, not receive inbound traffic.

2. **HEAD_SVC Environment Variable**
   Location: `pkg/controller/v1beta1/inferenceservice/components/predictor.go:595`
   ```go
   if err := isvcutils.AddEnvVarToPodSpec(mergedWorkerPodSpec, constants.WorkerContainerName, "HEAD_SVC",
       constants.GetHeadServiceName(isvc.Name, isvcGeneration)); err != nil {
   ```
   Worker pods get `HEAD_SVC` environment variable pointing to the headless head service DNS name.

3. **Service Creation Logic**
   Location: `pkg/controller/v1beta1/inferenceservice/reconcilers/service/service_reconciler.go:86-108`
   ```go
   if !multiNodeEnabled {
       // Only defaultSvc created
       defaultSvc := createDefaultSvc(componentMeta, componentExt, podSpec, serviceConfig)
       svcList = append(svcList, defaultSvc)
   } else if multiNodeEnabled && !isWorkerContainer {
       // For head node: both defaultSvc and headSvc created
       defaultSvc := createDefaultSvc(componentMeta, componentExt, podSpec, serviceConfig)
       svcList = append(svcList, defaultSvc)

       headSvc := createHeadlessSvc(componentMeta)
       svcList = append(svcList, headSvc)
   }
   // NOTE: When isWorkerContainer=true, NO services are created!
   ```

4. **Headless Service for Worker Discovery**
   Location: `pkg/controller/v1beta1/inferenceservice/reconcilers/service/service_reconciler.go:197-216`
   ```go
   func createHeadlessSvc(componentMeta metav1.ObjectMeta) *corev1.Service {
       workerComponentMeta := componentMeta.DeepCopy()
       predictorSvcName := workerComponentMeta.Name
       isvcGeneration := componentMeta.GetLabels()[constants.InferenceServiceGenerationPodLabelKey]
       workerComponentMeta.Name = constants.GetHeadServiceName(predictorSvcName, isvcGeneration)

       service := &corev1.Service{
           ObjectMeta: *workerComponentMeta,
           Spec: corev1.ServiceSpec{
               Selector: map[string]string{
                   "app": constants.GetRawServiceLabel(predictorSvcName),
                   constants.InferenceServiceGenerationPodLabelKey: isvcGeneration,
               },
               ClusterIP:                "None",  // Headless service
               PublishNotReadyAddresses: true,    // Allow connection during startup
           },
       }
       return service
   }
   ```

5. **Generation-Specific Headless Service Naming**
   Location: `pkg/constants/constants.go:591-594`
   ```go
   func GetHeadServiceName(service string, isvcGeneration string) string {
       isvcName := strings.TrimSuffix(service, "-predictor")
       return isvcName + "-" + MultiNodeHead + "-" + isvcGeneration
   }
   // Example: sklearn-iris-head-1, sklearn-iris-head-2, etc.
   ```

**Multi-Node Service Topology**:

```
┌─────────────────────────────────────────────────────────────┐
│                        HEAD NODE                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Pod: sklearn-iris-predictor-head                    │  │
│  │  Labels:                                             │  │
│  │    - app: isvc.sklearn-iris-predictor               │  │
│  │    - serving.kserve.io/...generation: "1"           │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  Services (2):                                              │
│  1. Default Service (for inference requests)                │
│     - Name: sklearn-iris-predictor                          │
│     - ClusterIP: <assigned>                                 │
│     - Selector: app=isvc.sklearn-iris-predictor            │
│     - Used by: HTTPRoute, external clients                  │
│                                                             │
│  2. Headless Service (for worker discovery)                 │
│     - Name: sklearn-iris-head-1                             │
│     - ClusterIP: None                                       │
│     - Selector: app=isvc.sklearn-iris-predictor AND        │
│                 generation="1"                              │
│     - Used by: Worker pods to discover head                 │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                      WORKER NODES                           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Pod: sklearn-iris-predictor-worker-0                │  │
│  │  Env: HEAD_SVC=sklearn-iris-head-1                   │  │
│  │  Command: ray start --address=$RAY_HEAD_ADDRESS      │  │
│  │           --block                                    │  │
│  │  → Connects TO head node (outbound only)             │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  Services: NONE                                             │
│  Workers do not receive external traffic!                   │
└─────────────────────────────────────────────────────────────┘
```

**Implications for Argo Rollouts**:

1. **Head Node Needs Rollout**:
   - Receives inference traffic via default service
   - Needs BlueGreen/Canary strategies for safe rollouts
   - Requires active + preview services (for Rollout traffic splitting)
   - Headless service auto-created per generation

2. **Worker Nodes DON'T Need Rollout**:
   - No inbound traffic routing
   - Workers connect TO head (outbound)
   - Can use standard Deployment
   - No services created for workers

3. **During Rollout**:
   ```
   Generation 1 (old):
     - Head Rollout (old version)
     - Headless Service: sklearn-iris-head-1
     - Worker Deployment (old) → connects to sklearn-iris-head-1

   Generation 2 (new):
     - Head Rollout (new version)
     - Headless Service: sklearn-iris-head-2
     - Worker Deployment (new) → connects to sklearn-iris-head-2

   Active Service: Points to new head after promotion
   Preview Service: Points to new head during testing
   Old workers talk to old head, new workers to new head!
   ```

4. **Simplified MVP Scope**:
   - **Phase 1**: Head Rollout + 3 services (active + preview + headless)
   - **Phase 1**: Worker Deployment (no change, no services)
   - Multi-node IS supported in Phase 1 MVP!

**Conclusion**: The user's insight was correct. Workers only need outbound connections to head nodes, so they don't require Rollout management or service routing. Only the head node needs Argo Rollout support with dual services.

---

#### 1.2 Deployment Creation Flow

**Entry Point**: `pkg/controller/v1beta1/inferenceservice/reconcilers/raw/raw_kube_reconciler.go`

```go
type RawKubeReconciler struct {
    client        client.Client
    scheme        *runtime.Scheme
    Deployment    *deployment.DeploymentReconciler  // Manages Deployments
    Service       *service.ServiceReconciler
    Scaler        *autoscaler.AutoscalerReconciler
    OtelCollector *otel.OtelReconciler
    URL           *knapis.URL
}
```

**Key Reconcilers**:
1. **DeploymentReconciler** (`pkg/controller/v1beta1/inferenceservice/reconcilers/deployment/deployment_reconciler.go`)
   - Creates Kubernetes Deployment resources
   - Supports head + worker Deployments for multi-node scenarios
   - Applies rollout strategies from ComponentExtensionSpec or ConfigMap
   - Handles GPU resource assignment
   - Line 76-137: `createRawDeployment()` - main creation logic
   - Line 139-174: `createRawDefaultDeployment()` - head node
   - Line 176-219: `createRawWorkerDeployment()` - worker nodes
   - Line 450-505: `Reconcile()` - reconciliation loop

2. **ServiceReconciler** (`pkg/controller/v1beta1/inferenceservice/reconcilers/service/service_reconciler.go`)
   - Creates single Kubernetes Service per component
   - Service selector: `app: <service-label>`
   - Pods labeled with same selector
   - **FINDING**: Current implementation creates only ONE service per component

3. **AutoscalerReconciler** (`pkg/controller/v1beta1/inferenceservice/reconcilers/autoscaler/`)
   - Supports HPA, KEDA, or None
   - Creates ScaleTarget referencing Deployment

#### 1.2 Deployment Strategy Configuration

**From ComponentExtensionSpec** (`pkg/apis/serving/v1beta1/component.go:82-132`):
```go
type ComponentExtensionSpec struct {
    // User can specify Kubernetes DeploymentStrategy directly
    DeploymentStrategy *appsv1.DeploymentStrategy `json:"deploymentStrategy,omitempty"`

    // ... other fields
}
```

**Priority Order**:
1. User-specified `DeploymentStrategy` (highest)
2. ConfigMap `DeploymentRolloutStrategy`
3. KServe defaults (MaxUnavailable: 25%, MaxSurge: 25%)

**ConfigMap Structure** (`pkg/apis/serving/v1beta1/configmap.go:131-151`):
```go
type DeployConfig struct {
    DefaultDeploymentMode     string
    DeploymentRolloutStrategy *DeploymentRolloutStrategy
}

type DeploymentRolloutStrategy struct {
    DefaultRollout *RolloutSpec
}

type RolloutSpec struct {
    MaxSurge       string  // e.g., "25%", "1"
    MaxUnavailable string  // e.g., "25%", "1"
}
```

**Documentation**: `docs/apis/v1beta1/ROLLOUT_STRATEGY_API.md` - Comprehensive rollout strategy docs already exist!

#### 1.3 Multi-Node Deployment Support

**For Ray Workloads** (lines 88-122 in deployment_reconciler.go):
- Detects `RAY_NODE_COUNT` environment variable
- Creates separate head and worker Deployments
- Head Deployment: Primary inference service
- Worker Deployment: Ray worker nodes with replicas = RAY_NODE_COUNT - 1
- Worker gets special rollout strategy: `MaxUnavailable: 0%, MaxSurge: 100%` (zero downtime)

---

### 2. Gateway API Integration

#### 2.1 HTTPRoute Reconciler

**Location**: `pkg/controller/v1beta1/inferenceservice/reconcilers/ingress/httproute_reconciler.go`

**Key Findings**:
```go
type RawHTTPRouteReconciler struct {
    client        client.Client
    scheme        *runtime.Scheme
    ingressConfig *v1beta1.IngressConfig
    isvcConfig    *v1beta1.InferenceServicesConfig
}
```

**HTTPRoute Creation**:
- Creates separate HTTPRoutes for predictor, transformer, explainer
- Uses `BackendRef` pointing to Service
- Path-based routing with regex matching
- **Current Traffic Management**: Single BackendRef per rule (no weighted splitting)

**Example BackendRef** (lines 200-220):
```go
BackendRefs: []gwapiv1.HTTPBackendRef{
    {
        BackendRef: gwapiv1.BackendRef{
            BackendObjectReference: gwapiv1.BackendObjectReference{
                Kind:      "Service",
                Name:      serviceName,
                Namespace: namespace,
                Port:      portNumber,
            },
        },
    },
}
```

**Configuration**:
- Gateway reference from `IngressConfig.KserveIngressGateway`
- Domain from `IngressConfig.IngressDomain`
- Path templates supported

#### 2.2 Traffic Splitting Capability

**Current State**:
- HTTPRoute points to single Service
- No weighted BackendRefs
- No traffic splitting in raw mode currently

**For Argo Rollouts**:
- **BlueGreen**: HTTPRoute points to active service, Rollout switches service selector atomically ✅
- **Canary**: Would need weighted BackendRefs pointing to both active and preview services (Phase 2)

---

### 3. Status Management

#### 3.1 InferenceServiceStatus Structure

**Location**: `pkg/apis/serving/v1beta1/inference_service_status.go`

```go
type InferenceServiceStatus struct {
    duckv1.Status `json:",inline"`  // Includes Conditions

    Address *duckv1.Addressable `json:"address,omitempty"`
    URL     *apis.URL           `json:"url,omitempty"`

    // Component-specific statuses
    Components map[ComponentType]ComponentStatusSpec `json:"components,omitempty"`

    ModelStatus    ModelStatus `json:"modelStatus,omitempty"`
    DeploymentMode string      `json:"deploymentMode,omitempty"`
}

type ComponentStatusSpec struct {
    LatestReadyRevision   string
    LatestCreatedRevision string
    Traffic               []knservingv1.TrafficTarget  // For Knative mode
    URL                   *apis.URL
    RestURL               *apis.URL
    GrpcURL               *apis.URL
}
```

**Condition Types**:
- PredictorReady
- TransformerReady
- ExplainerReady
- IngressReady
- RoutesReady
- LatestDeploymentReady

#### 3.2 Status Propagation

**For Deployments** (`PropagateRawStatus()` method):
- Reads Deployment conditions (Available, Progressing, ReplicaFailure)
- Maps to component readiness conditions
- Sets component URL when ready

**For Rollouts** (needs to be added):
- Read Rollout conditions (Available, Progressing, Degraded, Paused)
- Map to component readiness
- Track rollout-specific info (phase, pod hash, revision)

---

### 4. RBAC and Scheme Management

#### 4.1 Current RBAC Structure

**Location**: `config/rbac/role.yaml`

**Pattern**: Already supports optional integrations
```yaml
# KEDA (optional)
- apiGroups: [keda.sh]
  resources: [scaledobjects]
  verbs: [get, list, watch, create, update, patch, delete]

# Istio (optional)
- apiGroups: [networking.istio.io]
  resources: [virtualservices]
  verbs: [get, list, watch, create, update, patch, delete]

# Gateway API (optional)
- apiGroups: [gateway.networking.k8s.io]
  resources: [httproutes]
  verbs: [get, list, watch, create, update, patch, delete]
```

**Controller Markers**: `pkg/controller/v1beta1/inferenceservice/controller.go:66-97`
```go
// +kubebuilder:rbac:groups=keda.sh,resources=scaledobjects,verbs=...
// +kubebuilder:rbac:groups=networking.istio.io,resources=virtualservices,verbs=...
```

#### 4.2 Scheme Registration

**Location**: `cmd/manager/main.go` or controller initialization

**Pattern**: External CRDs registered in scheme
```go
import (
    kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
    istioclientv1beta1 "istio.io/client-go/pkg/apis/networking/v1beta1"
)
```

#### 4.3 CRD Availability Check

**Utility**: `pkg/utils/utils.go:196-213`
```go
func IsCrdAvailable(config *rest.Config, groupVersion, kind string) (bool, error) {
    gvResources, err := GetAvailableResourcesForApi(config, groupVersion)
    if err != nil {
        return false, err
    }

    found := false
    if gvResources != nil {
        for _, crd := range gvResources.APIResources {
            if crd.Kind == kind {
                found = true
                break
            }
        }
    }
    return found, nil
}
```

**Usage Pattern**: Controllers check CRD availability before registering watches

---

### 5. Conditional Feature Pattern

#### 5.1 Deployment Mode Selection

**Utility**: `pkg/controller/v1beta1/inferenceservice/utils/utils.go`

**Decision Logic**:
1. Check status.deploymentMode (persisted choice)
2. Check annotation `serving.kserve.io/deploymentMode`
3. Fallback to ConfigMap default

**Supported Modes**:
- `Knative` (Serverless)
- `Standard` (Raw Kubernetes)
- `ModelMesh`

#### 5.2 Autoscaler Class Selection

**Annotation**: `serving.kserve.io/autoscalerClass`

**Options**:
- `hpa` - Horizontal Pod Autoscaler
- `external` - KEDA ScaledObject
- `none` - Fixed replicas

**Pattern**: Annotation → Different reconciler creation

#### 5.3 Optional Components

**Transformer and Explainer**: Only created if spec includes them
```go
if isvc.Spec.Transformer != nil {
    reconcilers = append(reconcilers, components.NewTransformer(...))
}
if isvc.Spec.Explainer != nil {
    reconcilers = append(reconcilers, components.NewExplainer(...))
}
```

---

## Key Architectural Patterns

### Pattern 1: Reconciler Composition

RawKubeReconciler composes multiple sub-reconcilers:
- Deployment OR Rollout (mutually exclusive) ← **Opportunity**
- Service (always)
- Autoscaler (conditional)
- OTel (conditional)

**Implication**: Easy to add Rollout as alternative to Deployment

### Pattern 2: Annotation-Driven Behavior

Examples:
- `serving.kserve.io/deploymentMode`
- `serving.kserve.io/autoscalerClass`
- `serving.kserve.io/disable-auto-update`

**Implication**: `serving.kserve.io/enable-rollout` fits this pattern perfectly

### Pattern 3: Optional CRD Support

KEDA, Istio, OpenTelemetry are all optional:
- Check CRD availability
- Register scheme if available
- Add watches conditionally
- Graceful degradation if not present

**Implication**: Argo Rollouts can follow same pattern

### Pattern 4: Status Abstraction

Different deployment modes (Knative vs Standard) use different status propagation:
- `PropagateStatus()` for Knative
- `PropagateRawStatus()` for Standard
- Component-agnostic status structure

**Implication**: Add `PropagateRolloutStatus()` following same pattern

---

## Critical Discovery: Service Management Issue

### Initial Assumption (INCORRECT)
✗ "Service Management: No changes required - Services work identically"
✗ "Rollout references existing Service via activeService"

### Actual Requirement (CORRECT)
For Argo Rollouts **BlueGreen Strategy**, TWO services are required:

1. **Active Service** (`<component-name>`)
   - Points to stable/production pods
   - HTTPRoute BackendRef points here
   - Users access this service

2. **Preview Service** (`<component-name>-preview`)
   - Points to new pods during rollout
   - Used for testing/validation before promotion
   - Not exposed via HTTPRoute (MVP)

### BlueGreen Rollout Flow

```
1. Initial State:
   Active Service → Old Pods (v1)
   Preview Service → (none)

2. New Rollout Triggered:
   Active Service → Old Pods (v1)
   Preview Service → New Pods (v2)  [Can test via preview service]

3. After Promotion:
   Active Service → New Pods (v2)
   Preview Service → New Pods (v2)

4. After ScaleDown:
   Active Service → New Pods (v2)
   Preview Service → (none)
   Old Pods deleted
```

### Implementation Impact

**ServiceReconciler Changes Required**:

**Current** (`service_reconciler.go`):
```go
func NewServiceReconciler(...) *ServiceReconciler {
    // Creates single service
    service := createRawService(componentMeta, podSpec, ...)
    return &ServiceReconciler{
        Service: service,
        // ...
    }
}
```

**Required for Rollout**:
```go
func NewServiceReconciler(...) *ServiceReconciler {
    // Check if rollout is enabled
    enableRollout := componentMeta.Annotations[constants.EnableRolloutAnnotationKey] == "true"

    var services []*corev1.Service

    // Always create active service
    activeService := createRawService(componentMeta, podSpec, ...)
    services = append(services, activeService)

    if enableRollout {
        // Create preview service for rollout
        previewMeta := componentMeta.DeepCopy()
        previewMeta.Name = componentMeta.Name + "-preview"
        previewService := createRawService(*previewMeta, podSpec, ...)
        services = append(services, previewService)
    }

    return &ServiceReconciler{
        Services: services,  // Changed from Service to Services
        // ...
    }
}
```

**Rollout Strategy Configuration**:
```go
// In rollout_reconciler.go
Strategy: rolloutv1alpha1.RolloutStrategy{
    BlueGreen: &rolloutv1alpha1.BlueGreenStrategy{
        ActiveService:        componentMeta.Name,              // <component-name>
        PreviewService:       componentMeta.Name + "-preview", // <component-name>-preview
        AutoPromotionEnabled: ptr.To(true),
    },
}
```

**HTTPRoute Integration**:
- HTTPRoute BackendRef continues to point to active service
- Preview service not exposed externally (MVP)
- Users can manually access preview service for testing if needed

---

## Compatibility Analysis

### ✅ Compatible Components (No Changes)

1. **Gateway API / HTTPRoute**
   - HTTPRoute points to active Service
   - Service selector updated by Rollout controller
   - Zero changes needed for MVP

2. **Storage Initializer**
   - Operates at Pod template level
   - Works identically with Rollout PodSpec

3. **Multi-Node GPU Support**
   - Environment variables (RAY_NODE_COUNT, REQUEST_GPU_COUNT)
   - Pod-level configuration
   - Compatible with Rollout

### ⚠️ Requires Changes

1. **ServiceReconciler** ⚠️ CRITICAL
   - Must create TWO services (active + preview)
   - Service list vs single service
   - Reconcile loop for both services

2. **DeploymentReconciler vs RolloutReconciler**
   - Mutually exclusive
   - RolloutReconciler follows same pattern as DeploymentReconciler

3. **Status Propagation**
   - Add PropagateRolloutStatus()
   - Map Rollout conditions to InferenceService conditions

4. **Component Reconcilers (Predictor/Transformer/Explainer)**
   - Check if using Rollout
   - Call appropriate status propagation method

### 🔍 Needs Validation

1. **HPA with Rollout**
   - Argo Rollouts claims HPA compatibility
   - Need to verify ScaleTargetRef works
   - Test with KServe's HPA setup

2. **KEDA with Rollout**
   - KEDA supports Rollout as scale target
   - Need to verify integration

3. **Force-Stop Annotation**
   - Should work similarly to Deployment
   - Rollout deletion flow

---

## Argo Rollouts API Overview

### Rollout Resource Structure

```go
type Rollout struct {
    Spec RolloutSpec
    Status RolloutStatus
}

type RolloutSpec struct {
    Replicas *int32
    Selector *metav1.LabelSelector
    Template corev1.PodTemplateSpec  // Same as Deployment
    Strategy RolloutStrategy
}

type RolloutStrategy struct {
    BlueGreen *BlueGreenStrategy
    Canary    *CanaryStrategy
}

type BlueGreenStrategy struct {
    ActiveService          string   // Name of active service
    PreviewService         string   // Name of preview service
    AutoPromotionEnabled   *bool
    AutoPromotionSeconds   *int32
    ScaleDownDelaySeconds  *int32
    PreviewReplicaCount    *int32
}
```

### Rollout Conditions

```go
const (
    RolloutAvailable      RolloutConditionType = "Available"
    RolloutProgressing    RolloutConditionType = "Progressing"
    RolloutReplicaFailure RolloutConditionType = "ReplicaFailure"
    RolloutPaused         RolloutConditionType = "Paused"
    RolloutCompleted      RolloutConditionType = "Completed"
    RolloutDegraded       RolloutConditionType = "Degraded"
)
```

### Rollout Status

```go
type RolloutStatus struct {
    ObservedGeneration  int64
    HPAReplicas         int32
    AvailableReplicas   int32
    CurrentPodHash      string
    StableRS            string  // Stable ReplicaSet
    CurrentStepIndex    *int32
    Phase               RolloutPhase
    Conditions          []RolloutCondition
    Canary              CanaryStatus
    BlueGreen           BlueGreenStatus
}
```

---

## Dependencies and Prerequisites

### Go Module Dependencies

```go
require (
    github.com/argoproj/argo-rollouts v1.7.0  // Latest stable
)
```

### Cluster Prerequisites (Optional)

For users who want Rollout support:
```bash
# Install Argo Rollouts CRDs
kubectl apply -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Install Argo Rollouts controller
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/namespace-install.yaml
```

### KServe Dependencies

Already present:
- controller-runtime (for client and scheme)
- Gateway API types
- Knative types (for status duck typing)

---

## Risk Assessment

### Low Risk ✅

1. **Backward Compatibility**
   - Opt-in via annotation
   - Existing Deployments unchanged
   - No breaking changes

2. **Code Isolation**
   - New RolloutReconciler isolated
   - Minimal changes to existing reconcilers
   - Clear separation of concerns

3. **Feature Flags**
   - CRD availability check prevents errors
   - Graceful degradation if Argo not installed

### Medium Risk ⚠️

1. **Service Management Complexity**
   - Need to manage TWO services per component
   - Preview service lifecycle
   - Service reconciliation loop changes

2. **Multi-Node Coordination**
   - Head and worker Rollouts must coordinate
   - ScaleDownDelaySeconds critical for Ray cluster stability

3. **Testing Coverage**
   - Need comprehensive E2E tests
   - Multiple autoscaler combinations
   - Migration scenarios

### High Risk 🔴

1. **Status Synchronization**
   - Rollout status → InferenceService status mapping
   - Multiple Rollouts (head + worker) → single status
   - Potential race conditions

---

## Recommendations

### Phase 1 (MVP)

1. **Start Simple**
   - BlueGreen strategy only
   - Auto-promotion enabled
   - Single-node scenarios first

2. **Service Management** ⚠️ CRITICAL FIX
   - Update ServiceReconciler to create both active and preview services
   - Service list management
   - Proper cleanup on rollout disable

3. **Comprehensive Testing**
   - Unit tests for all new code
   - Integration tests with actual Rollout controller
   - Migration testing (Deployment ↔ Rollout)

### Phase 2 (Future)

1. **Canary Strategy**
   - HTTPRoute weighted BackendRefs
   - Step-based promotion
   - Analysis templates

2. **Advanced Features**
   - Manual promotion
   - Rollback capabilities
   - Metrics-based validation

### Phase 3 (Future)

1. **API Evolution**
   - Move from annotation to CRD field
   - Typed rollout configuration
   - Validation webhooks

---

## Open Questions

1. **Service Naming** ✅ RESOLVED
   - Active: `<component-name>`
   - Preview: `<component-name>-preview`

2. **HTTPRoute Integration**
   - MVP: Point to active service only ✅
   - Future: Weighted routing for canary

3. **Multi-Node Rollout Order**
   - Should head rollout before workers? Or parallel?
   - BlueGreen makes this less critical (atomic switch)

4. **Autoscaler Target**
   - HPA/KEDA should target Rollout
   - Need validation that this works correctly

5. **Migration Safety**
   - Should we auto-delete Deployment when enabling Rollout?
   - Recommendation: No, user manual cleanup for safety ✅

---

## Conclusion

**Feasibility**: ✅ HIGHLY FEASIBLE

**Complexity**: Medium (with Service management correction)

**Timeline**: 4-5 weeks for MVP

**Key Success Factor**: Proper dual-service management for BlueGreen strategy

**Next Steps**:
1. Update implementation plan with dual-service approach
2. Start with constants and RolloutReconciler skeleton
3. Implement ServiceReconciler changes (critical path)
4. Add status propagation
5. Comprehensive testing
