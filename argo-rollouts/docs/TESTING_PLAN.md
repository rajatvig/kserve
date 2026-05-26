# Argo Rollout Testing Plan for KServe

**Last Updated**: 2025-12-21
**Scope**: kind-based local testing for single-node InferenceService rollouts

## Overview

This testing plan covers verification of Argo Rollout integration with KServe InferenceServices in raw deployment mode. Testing focuses on single-node deployments in a local kind (Kubernetes IN Docker) cluster.

## Test Environment

### Infrastructure
- **Cluster**: kind v0.20.0+
- **Kubernetes**: v1.28+
- **Gateway API**: v1.0.0
- **Gateway Implementation**: Envoy Gateway (lightweight for testing)
- **Argo Rollouts**: Latest stable release
- **KServe**: Development build with Rollout support

### Cluster Configuration
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kserve-rollout-test
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
```

## Test Scenarios

### Scenario 1: Standard Deployment (Baseline)

**Objective**: Verify existing KServe functionality without Rollouts

**InferenceService**:
- Model: sklearn iris classifier
- Deployment Mode: RawDeployment
- **NO** rollout annotation

**Expected Resources**:
- ✅ 1 Deployment: `sklearn-iris-predictor`
- ✅ 1 Service: `sklearn-iris-predictor`
- ✅ 1 HTTPRoute: `sklearn-iris-predictor`
- ❌ NO Rollout resource
- ❌ NO preview service

**Verification Steps**:
1. Deploy InferenceService
2. Wait for Ready condition
3. Verify Deployment exists
4. Verify Rollout does NOT exist
5. Verify single service exists
6. Test inference endpoint
7. Update model storageUri
8. Verify standard rolling update (not BlueGreen)

**Success Criteria**:
- InferenceService reaches Ready state
- Inference request returns HTTP 200
- Update completes via Deployment rolling update
- No Rollout resources created

---

### Scenario 2: Rollout Deployment (New Feature)

**Objective**: Verify Argo Rollout integration

**InferenceService**:
- Model: sklearn iris classifier
- Deployment Mode: RawDeployment
- **WITH** rollout annotation: `serving.kserve.io/enable-rollout: "true"`

**Expected Resources**:
- ✅ 1 Rollout: `sklearn-iris-predictor`
- ✅ 2 Services: `sklearn-iris-predictor` (active), `sklearn-iris-predictor-preview` (preview)
- ✅ 1 HTTPRoute: `sklearn-iris-predictor` (pointing to active service)
- ❌ NO Deployment resource

**Verification Steps**:
1. Deploy InferenceService with rollout annotation
2. Wait for Ready condition
3. Verify Rollout exists (not Deployment)
4. Verify active service exists
5. Verify preview service exists
6. Verify HTTPRoute points to active service only
7. Test inference endpoint
8. Update model storageUri
9. Watch BlueGreen rollout progression
10. Verify preview service routes to new pods during rollout
11. Verify active service switches to new pods after promotion
12. Verify old ReplicaSet scaled down after delay

**Success Criteria**:
- InferenceService reaches Ready state
- Rollout resource created (not Deployment)
- Dual services created (active + preview)
- Inference request returns HTTP 200
- Update uses BlueGreen strategy (not rolling update)
- Zero downtime during promotion
- Old pods scaled down after ScaleDownDelaySeconds

---

### Scenario 3: Rollout Status Propagation

**Objective**: Verify InferenceService status reflects Rollout state

**Verification Steps**:
1. Deploy InferenceService with rollout
2. Check `status.components.predictor.rolloutStatus` populated
3. Verify phase (Healthy, Progressing, Degraded)
4. Update model
5. During rollout, verify status shows Progressing
6. After promotion, verify status shows Healthy
7. Verify currentPodHash and stableRevision fields

**Success Criteria**:
- `rolloutStatus` field appears in component status
- Status accurately reflects Rollout phase
- Conditions map correctly from Rollout to InferenceService

---

### Scenario 4: Service Management

**Objective**: Verify dual service creation and lifecycle

**Verification Steps**:
1. Deploy InferenceService with rollout
2. Verify active service created immediately
3. Verify preview service created
4. Check service selectors match Rollout labels
5. Verify HTTPRoute only references active service
6. Update model
7. During rollout:
   - Preview service endpoints point to new ReplicaSet
   - Active service endpoints still point to old ReplicaSet
8. After promotion:
   - Active service endpoints switch to new ReplicaSet
   - Preview service endpoints match active

**Success Criteria**:
- Both services created with correct names
- Service selectors correctly configured
- Preview service isolated during rollout
- Active service switches atomically during promotion

---

### Scenario 5: Migration (Deployment → Rollout)

**Objective**: Verify existing Deployment can be migrated to Rollout

**Steps**:
1. Deploy InferenceService without rollout annotation
2. Verify Deployment created
3. Test inference works
4. Update InferenceService, add rollout annotation
5. Apply updated manifest
6. Verify:
   - Rollout created
   - Old Deployment removed
   - Preview service created
   - No downtime during migration

**Success Criteria**:
- Migration completes successfully
- Inference continues working throughout
- Resources transition from Deployment to Rollout
- No manual intervention required

---

### Scenario 6: Migration (Rollout → Deployment)

**Objective**: Verify Rollout can be reverted to standard Deployment

**Steps**:
1. Deploy InferenceService with rollout annotation
2. Verify Rollout created
3. Update InferenceService, remove rollout annotation
4. Apply updated manifest
5. Verify:
   - Deployment created
   - Old Rollout removed
   - Preview service removed
   - Only active service remains

**Success Criteria**:
- Migration completes successfully
- Resources transition from Rollout to Deployment
- Preview service cleaned up
- Inference continues working

---

### Scenario 7: Error Handling

**Objective**: Verify graceful failure when Argo Rollouts not installed

**Steps**:
1. Remove Argo Rollouts CRD from cluster
2. Deploy InferenceService with rollout annotation
3. Verify:
   - InferenceService status shows error
   - Error message indicates Argo Rollouts not available
   - No crash loops or controller failures

**Success Criteria**:
- Clear error message in InferenceService status
- Controller continues functioning for other InferenceServices
- System remains stable

---

## Test Matrix

| Scenario | Rollout Annotation | Expected Resource | Service Count | HTTPRoute Backend |
|----------|-------------------|-------------------|---------------|-------------------|
| Standard | None | Deployment | 1 (active) | Active service |
| Rollout | `"true"` | Rollout | 2 (active + preview) | Active service |
| Migration D→R | Add `"true"` | Rollout | 2 | Active service |
| Migration R→D | Remove | Deployment | 1 | Active service |

## Automated Test Execution

### Script Flow

```
01-setup-cluster.sh
    ↓
02-install-components.sh
    ↓
03-test-standard-deployment.sh (Scenario 1)
    ↓
04-test-rollout-deployment.sh (Scenarios 2-4)
    ↓
99-cleanup.sh (optional)
```

### Test Scripts

#### `01-setup-cluster.sh`
- Create kind cluster with proper configuration
- Verify cluster health
- Load required images

#### `02-install-components.sh`
- Install Gateway API CRDs
- Install Envoy Gateway
- Install Argo Rollouts
- Wait for controllers to be ready
- Install KServe (with Rollout support)
- Create Gateway resource

#### `03-test-standard-deployment.sh`
- Deploy sklearn InferenceService (no rollout)
- Verify Deployment created
- Test inference
- Update model
- Verify rolling update
- Cleanup

#### `04-test-rollout-deployment.sh`
- Deploy sklearn InferenceService (with rollout)
- Verify Rollout created
- Verify dual services
- Test inference
- Update model
- Verify BlueGreen rollout
- Verify status propagation
- Cleanup

#### `99-cleanup.sh`
- Delete InferenceServices
- Delete kind cluster

### Common Functions (`common.sh`)

```bash
# Error handling
set -euo pipefail
trap 'error_handler $? $LINENO' ERR

# Logging
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_success() { echo "[SUCCESS] $*"; }

# Kubernetes helpers
wait_for_pod() { ... }
wait_for_condition() { ... }
check_resource_exists() { ... }
check_resource_not_exists() { ... }

# Inference testing
test_inference() { ... }
```

## Test Data

### Sample InferenceService Manifests

**Standard Deployment** (`sklearn-standard.yaml`):
```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: sklearn-iris
  annotations:
    serving.kserve.io/deploymentMode: "RawDeployment"
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      storageUri: "gs://kfserving-examples/models/sklearn/1.0/model"
```

**Rollout Deployment** (`sklearn-rollout.yaml`):
```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: sklearn-iris-rollout
  annotations:
    serving.kserve.io/deploymentMode: "RawDeployment"
    serving.kserve.io/enable-rollout: "true"
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      storageUri: "gs://kfserving-examples/models/sklearn/1.0/model"
```

### Test Inference Payload

```json
{
  "instances": [
    [6.8, 2.8, 4.8, 1.4],
    [6.0, 3.4, 4.5, 1.6]
  ]
}
```

**Expected Response**:
```json
{
  "predictions": [1, 1]
}
```

## Verification Checklist

### Pre-Deployment
- [ ] kind cluster running
- [ ] Gateway API CRDs installed
- [ ] Envoy Gateway running
- [ ] Argo Rollouts controller running
- [ ] KServe controller running
- [ ] Gateway resource created

### Standard Deployment
- [ ] InferenceService Ready
- [ ] Deployment exists
- [ ] Rollout does NOT exist
- [ ] 1 service exists
- [ ] HTTPRoute exists
- [ ] Inference returns 200
- [ ] Update triggers rolling update

### Rollout Deployment
- [ ] InferenceService Ready
- [ ] Rollout exists
- [ ] Deployment does NOT exist
- [ ] Active service exists
- [ ] Preview service exists
- [ ] HTTPRoute points to active service
- [ ] Inference returns 200
- [ ] Update triggers BlueGreen rollout
- [ ] Preview service routes to new pods during rollout
- [ ] Active service switches after promotion
- [ ] Old ReplicaSet scaled down
- [ ] RolloutStatus in InferenceService status

### Status Verification
- [ ] `status.components.predictor.rolloutStatus` populated
- [ ] `rolloutStatus.phase` shows correct state
- [ ] `rolloutStatus.currentPodHash` populated
- [ ] `rolloutStatus.stableRevision` populated
- [ ] Rollout conditions mapped to InferenceService conditions

## Known Limitations (kind-specific)

1. **No GPU Testing**: kind doesn't support GPUs, use CPU-only models
2. **LoadBalancer**: Requires MetalLB or port-forward for external access
3. **DNS**: May need `/etc/hosts` entries for hostname-based routing
4. **Storage**: Use publicly accessible model URIs (GCS, S3 with public access)

## Debugging Commands

```bash
# Check Rollout status
kubectl argo rollouts get rollout sklearn-iris-rollout-predictor

# Watch Rollout progression
kubectl argo rollouts get rollout sklearn-iris-rollout-predictor --watch

# Check service endpoints
kubectl get endpoints sklearn-iris-rollout-predictor
kubectl get endpoints sklearn-iris-rollout-predictor-preview

# Check HTTPRoute configuration
kubectl get httproute sklearn-iris-rollout-predictor -o yaml

# Check InferenceService status
kubectl get isvc sklearn-iris-rollout -o yaml

# Check controller logs
kubectl logs -n kserve -l control-plane=kserve-controller-manager

# Check Argo Rollouts controller logs
kubectl logs -n argo-rollouts -l app.kubernetes.io/name=argo-rollouts
```

## Success Metrics

### Functional
- ✅ All test scenarios pass
- ✅ Zero downtime during BlueGreen promotion
- ✅ Status accurately reflects Rollout state
- ✅ Services managed correctly
- ✅ Migration paths work bidirectionally

### Non-Functional
- ✅ Tests complete in < 10 minutes
- ✅ No manual intervention required
- ✅ Clear error messages on failure
- ✅ Reproducible results across runs

## Future Test Scenarios (Out of Scope for MVP)

- Multi-node Ray serving with Rollout
- Canary deployment strategy
- Analysis templates for automated rollback
- Manual promotion (autoPromotionEnabled=false)
- Integration with external metrics (Prometheus)
- HPA + Rollout interaction
- KEDA + Rollout interaction

## References

- Implementation Plan: `ARGO_ROLLOUT_IMPLEMENTATION_PLAN.md`
- Investigation Report: `ARGO_ROLLOUT_INVESTIGATION.md`
- Session Notes: `ARGO_ROLLOUT_SESSION_NOTES.md`
- Argo Rollouts Docs: https://argo-rollouts.readthedocs.io/
- Gateway API Docs: https://gateway-api.sigs.k8s.io/
