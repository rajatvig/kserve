# Argo Rollout Support in KServe

## **Shared with KServe Community**

| Owner: Rajat Vig | Status: WIP |
| ----- | :---- |
| **Working Group**: Serving | **Created**: 2025-01-27 |

# Motivation / Abstract

Add Argo Rollouts as an alternative workload controller for KServe InferenceServices in raw deployment mode. Enables BlueGreen and Canary deployment strategies with zero-downtime updates for ML model serving.

**Personas**: Platform operators, ML engineers deploying production models

**Problem**: Standard Kubernetes Deployments use rolling updates which can cause brief downtime and don't allow pre-promotion testing of new model versions.

**Capability**: Support `ArgoRollout` deployment mode that creates Argo Rollout resources instead of Deployments, enabling atomic traffic switching and preview service testing.

# Background

## Current State

| Component | Status |
|-----------|--------|
| Interface-based factory pattern | **MERGED** (e74e1a267) |
| `WorkloadReconciler`, `ServiceReconciler`, `IngressReconciler` interfaces | **MERGED** |
| `ReconcilerFactory` with deployment mode switching | **MERGED** |
| Argo Rollout reconciler implementation | **NOT STARTED** |
| Rollout service reconciler (dual services) | **NOT STARTED** |
| Status propagation for Rollouts | **NOT STARTED** |

## Goals

- BlueGreen deployment strategy with zero-downtime updates
- Preview service for testing new model versions before promotion
- Automatic promotion after health checks pass
- Graceful degradation when Argo Rollouts not installed

## Non-Goals

- Canary strategy (Phase 2)
- Analysis templates and automated rollback (Phase 2)
- Changes to Serverless/Knative mode

# Proposal Design / Approach

## Design

### Deployment Mode Annotation

```yaml
annotations:
  serving.kserve.io/deploymentMode: "ArgoRollout"
```

Three modes: `Serverless` (Knative), `Standard` (Deployment), `ArgoRollout` (Rollout)

### Resource Comparison

| | Standard Mode | ArgoRollout Mode |
|---|---|---|
| Workload | Deployment | Rollout |
| Services | 1 (active) | 2 (active + preview) |
| HTTPRoute | Points to active | Points to active (unchanged) |
| Update strategy | Rolling update | BlueGreen (atomic switch) |
| Downtime | Possible | Zero |
| Pre-promotion testing | No | Yes (via preview service) |

### Architecture

```
InferenceService (deploymentMode: ArgoRollout)
    |
ReconcilerFactory.CreateWorkloadReconciler()
    |
RolloutReconciler (creates Rollout instead of Deployment)
    |
Rollout + Active Service + Preview Service + HTTPRoute
    |
Argo Rollouts controller manages BlueGreen promotion
```

### Multi-Node (Ray Serving)

Workers only make outbound connections to head nodes. They do not receive inbound traffic.

- **Head node**: Rollout + dual services (active + preview + headless)
- **Worker nodes**: Standard Deployment (no Rollout needed, no services)

### BlueGreen Strategy Configuration

```go
Strategy: rolloutv1alpha1.RolloutStrategy{
    BlueGreen: &rolloutv1alpha1.BlueGreenStrategy{
        ActiveService:         componentMeta.Name,
        PreviewService:        componentMeta.Name + "-preview",
        AutoPromotionEnabled:  ptr.To(true),
        ScaleDownDelaySeconds: ptr.To(int32(30)),
    },
}
```

### Service Naming

- Active: `<component-name>` (e.g., `sklearn-iris-predictor`)
- Preview: `<component-name>-preview` (e.g., `sklearn-iris-predictor-preview`)
- Headless (multi-node): `<isvc-name>-head-<generation>`

## Implementation

### Files to Create

| File | Purpose |
|------|---------|
| `pkg/controller/.../reconcilers/rollout/rollout_reconciler.go` | Creates Rollout resources with BlueGreen strategy |
| `pkg/controller/.../reconcilers/service/rollout_service_reconciler.go` | Creates active + preview services |

### Files to Modify

| File | Change |
|------|--------|
| `pkg/constants/constants.go` | Add `ArgoRollout` deployment mode, Rollout constants |
| `pkg/controller/.../reconcilers/factory.go` | Add `ArgoRollout` case to switch statements |
| `config/rbac/role.yaml` | Add `argoproj.io/rollouts` permissions |
| `cmd/manager/main.go` | Register Argo Rollouts scheme (conditional) |
| `pkg/controller/.../controller.go` | Watch Rollout resources (conditional on CRD) |

## Prerequisites / Dependencies

**Go module**: `github.com/argoproj/argo-rollouts v1.7.0+`

**Cluster (optional)**: Argo Rollouts CRDs and controller. Feature gracefully degrades if not installed - controller returns error in InferenceService status.

# Integration Checklist

## Operations

- User adds annotation `serving.kserve.io/deploymentMode: "ArgoRollout"` to InferenceService
- Requires Argo Rollouts controller installed in cluster
- No operator configuration changes required

## Observability

- InferenceService status includes `rolloutStatus` field with phase, pod hash, revision
- Rollout conditions mapped to InferenceService conditions
- Argo Rollouts dashboard compatible

## Test Plan

- Unit tests for RolloutReconciler and RolloutServiceReconciler
- Integration tests added to `test/` folder with Argo Rollouts installation support
- E2E test scenarios:
  1. Standard deployment creates Deployment (baseline)
  2. ArgoRollout mode creates Rollout + dual services
  3. BlueGreen promotion works (preview -> active switch)
  4. Status propagation (Rollout conditions -> InferenceService)
  5. Migration: Standard <-> ArgoRollout
  6. Error handling when Argo Rollouts not installed

## Documentation

- User guide for enabling Argo Rollout mode
- API reference for new status fields
- Migration guide between deployment modes

# Exit Criteria

## Alpha

- RolloutReconciler creates Rollout with BlueGreen strategy
- RolloutServiceReconciler creates active + preview services
- Basic status propagation
- Unit tests pass

## Beta

- Multi-node Ray serving support
- Complete status propagation
- E2E tests pass
- Documentation complete

## GA

- Production usage feedback incorporated
- Performance validated at scale
- Canary strategy support (Phase 2)

# Alternatives Considered

1. **Modify existing DeploymentReconciler**: Rejected - violates single responsibility, increases complexity

2. **Separate annotation for rollout enable**: Rejected - single `deploymentMode` annotation is cleaner and follows existing pattern

3. **Support Canary in Phase 1**: Rejected - BlueGreen is simpler MVP, Canary requires Gateway API traffic plugin integration
