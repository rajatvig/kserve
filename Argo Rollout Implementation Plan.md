# Argo Rollout Implementation Plan

## Overview

Implementation plan for adding Argo Rollout support to KServe. Phase 1 (interface refactoring) is complete. This plan covers Phase 2: adding the actual Rollout support.

## Prerequisites (Complete)

- [x] `WorkloadReconciler` interface defined
- [x] `ServiceReconciler` interface defined
- [x] `IngressReconciler` interface defined
- [x] `ReconcilerFactory` with deployment mode switching
- [x] `DeploymentReconciler` implements `WorkloadReconciler`
- [x] `ServiceReconciler` implements `ServiceReconciler` interface

## Implementation Tasks

### 1. Constants and Types

**File**: `pkg/constants/constants.go`

```go
// Add deployment mode
const ArgoRollout DeploymentModeType = "ArgoRollout"

// Add Rollout constants
const (
    RolloutAPIVersion   = "argoproj.io/v1alpha1"
    RolloutKind         = "Rollout"
    RolloutPreviewLabel = "serving.kserve.io/rollout-preview"
)
```

**File**: `pkg/constants/constants.go` - Update `ParseDeploymentMode()`

Add case for `"ArgoRollout"` returning `constants.ArgoRollout`

---

### 2. RolloutReconciler

**New File**: `pkg/controller/v1beta1/inferenceservice/reconcilers/rollout/rollout_reconciler.go`

```go
type RolloutReconciler struct {
    client       client.Client
    scheme       *runtime.Scheme
    RolloutList  []*rolloutv1alpha1.Rollout
    componentExt *v1beta1.ComponentExtensionSpec
}

// Must implement WorkloadReconciler interface:
// - Reconcile(ctx) ([]*appsv1.Deployment, error)
// - GetWorkloads() []metav1.Object
// - SetControllerReferences(owner, scheme) error
```

Key implementation details:
- Check CRD availability via `utils.IsCrdAvailable()`
- Create Rollout with BlueGreen strategy
- Convert Rollout status to Deployment status for compatibility
- Support multi-node: only create Rollout for head, not workers

---

### 3. RolloutServiceReconciler

**New File**: `pkg/controller/v1beta1/inferenceservice/reconcilers/service/rollout_service_reconciler.go`

```go
type RolloutServiceReconciler struct {
    client          client.Client
    scheme          *runtime.Scheme
    ActiveService   *corev1.Service
    PreviewService  *corev1.Service
    HeadlessService *corev1.Service // multi-node only
}

// Must implement ServiceReconciler interface:
// - Reconcile(ctx) ([]*corev1.Service, error)
// - GetServiceList() []*corev1.Service
// - SetControllerReferences(owner, scheme) error
```

Key implementation details:
- Active service: `<component-name>`
- Preview service: `<component-name>-preview`
- Headless service for multi-node worker discovery

---

### 4. Update Factory

**File**: `pkg/controller/v1beta1/inferenceservice/reconcilers/factory.go`

Add `ArgoRollout` case to:

```go
func (f *ReconcilerFactory) CreateWorkloadReconciler(...) {
    switch deploymentMode {
    case constants.ArgoRollout:
        return rollout.NewRolloutReconciler(...)
    // existing cases...
    }
}

func (f *ReconcilerFactory) CreateServiceReconciler(...) {
    switch deploymentMode {
    case constants.ArgoRollout:
        return service.NewRolloutServiceReconciler(...)
    // existing cases...
    }
}
```

---

### 5. RBAC Permissions

**File**: `config/rbac/role.yaml`

```yaml
- apiGroups:
  - argoproj.io
  resources:
  - rollouts
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
- apiGroups:
  - argoproj.io
  resources:
  - rollouts/status
  verbs:
  - get
  - update
  - patch
```

**File**: `pkg/controller/v1beta1/inferenceservice/controller.go`

Add kubebuilder markers:
```go
// +kubebuilder:rbac:groups=argoproj.io,resources=rollouts,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=argoproj.io,resources=rollouts/status,verbs=get;update;patch
```

---

### 6. Scheme Registration

**File**: `cmd/manager/main.go`

```go
import rolloutv1alpha1 "github.com/argoproj/argo-rollouts/pkg/apis/rollouts/v1alpha1"

// In scheme setup (conditional):
if err := rolloutv1alpha1.AddToScheme(scheme); err != nil {
    setupLog.Info("Argo Rollouts scheme not registered - CRD not available")
}
```

---

### 7. Controller Watch

**File**: `pkg/controller/v1beta1/inferenceservice/controller.go`

In `SetupWithManager()`, conditionally watch Rollouts:

```go
rolloutAvailable, _ := utils.IsCrdAvailable(config, "argoproj.io/v1alpha1", "Rollout")
if rolloutAvailable {
    builder = builder.Owns(&rolloutv1alpha1.Rollout{})
}
```

---

### 8. Go Module Dependency

**File**: `go.mod`

```
require github.com/argoproj/argo-rollouts v1.7.0
```

Run `go mod tidy`

---

### 9. Status Propagation (Optional for Alpha)

**File**: `pkg/apis/serving/v1beta1/inference_service_status.go`

Add `RolloutStatusInfo` type and update `ComponentStatusSpec`:

```go
type RolloutStatusInfo struct {
    Phase          string `json:"phase,omitempty"`
    CurrentPodHash string `json:"currentPodHash,omitempty"`
    StableRevision string `json:"stableRevision,omitempty"`
}

type ComponentStatusSpec struct {
    // existing fields...
    RolloutStatus *RolloutStatusInfo `json:"rolloutStatus,omitempty"`
}
```

---

### 10. Tests

**Unit Tests**:
- `pkg/controller/.../reconcilers/rollout/rollout_reconciler_test.go`
- `pkg/controller/.../reconcilers/service/rollout_service_reconciler_test.go`
- Update `pkg/controller/.../reconcilers/factory_test.go`

**Integration Tests**:
- Add Argo Rollouts installation to `test/` infrastructure
- Add E2E tests for ArgoRollout deployment mode

---

## Task Order

| Order | Task | Dependency |
|-------|------|------------|
| 1 | Add constants and types | None |
| 2 | Add go.mod dependency | None |
| 3 | Add RBAC permissions | None |
| 4 | Scheme registration | Task 2 |
| 5 | RolloutReconciler | Tasks 1, 2 |
| 6 | RolloutServiceReconciler | Task 1 |
| 7 | Update factory | Tasks 5, 6 |
| 8 | Controller watch | Tasks 4, 5 |
| 9 | Unit tests | Tasks 5, 6, 7 |
| 10 | Status propagation | Task 5 |
| 11 | E2E tests | All above |

---

## Verification

After implementation, verify:

1. `kubectl apply` InferenceService with `deploymentMode: ArgoRollout`
2. Check Rollout created (not Deployment)
3. Check both services created (active + preview)
4. Check HTTPRoute points to active service
5. Update model, verify BlueGreen promotion
6. Check InferenceService status reflects Rollout state
