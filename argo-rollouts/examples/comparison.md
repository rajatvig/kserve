# Standard vs ArgoRollout Deployment Mode Comparison

## Input: Same InferenceService, Different Modes

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: sklearn-iris
  annotations:
    serving.kserve.io/deploymentMode: "Standard"  # OR "ArgoRollout"
spec:
  predictor:
    minReplicas: 1
    model:
      modelFormat:
        name: sklearn
      storageUri: "gs://kfserving-examples/models/sklearn/1.0/model"
```

## Output Comparison

### Standard Mode (Default)

**Resources Created:**
1. ✅ 1x Deployment (`sklearn-iris-predictor`)
2. ✅ 1x Service (`sklearn-iris-predictor`)
3. ✅ 1x HTTPRoute (`sklearn-iris-predictor`)
4. ✅ 1x HPA (optional, if autoscaling enabled)

**Update Strategy:**
- Rolling update (default Deployment strategy)
- Gradual pod replacement
- Brief downtime possible during pod termination

**Architecture:**
```
HTTPRoute
   ↓
Service (single)
   ↓
Deployment
   ├─ ReplicaSet-1 (old) → scaling down
   └─ ReplicaSet-2 (new) → scaling up
```

---

### ArgoRollout Mode

**Resources Created:**
1. ✅ 1x Rollout (`sklearn-iris-predictor`) - **instead of Deployment**
2. ✅ 2x Services:
   - Active: `sklearn-iris-predictor`
   - Preview: `sklearn-iris-predictor-preview`
3. ✅ 1x HTTPRoute (`sklearn-iris-predictor`)
4. ✅ 1x HPA (optional, targets Rollout instead of Deployment)

**Update Strategy:**
- BlueGreen deployment
- Full new version deployed alongside old
- Preview service for testing
- Atomic traffic switch (zero downtime)
- Delayed scale-down of old version (30s)

**Architecture:**
```
HTTPRoute
   ↓
Active Service ──────┐
                     ↓
Preview Service      Rollout
   ↓                    ├─ ReplicaSet-1 (old) ← Active pods
   ↓                    └─ ReplicaSet-2 (new) ← Preview pods
   └─────────────────────────────────────────┘
   (can test new version before promotion)
```

---

## Key Differences

| Aspect | Standard Mode | ArgoRollout Mode |
|--------|---------------|------------------|
| **Primary Resource** | Deployment | Rollout |
| **Services** | 1 (active only) | 2 (active + preview) |
| **Update Strategy** | Rolling Update | BlueGreen |
| **Testing New Version** | Not possible | Via preview service |
| **Traffic Switch** | Gradual | Atomic |
| **Downtime** | Possible (brief) | Zero |
| **Old Version Cleanup** | Immediate | Delayed (30s) |
| **Rollback** | Via kubectl rollout undo | Via Argo Rollouts (instant) |
| **Promotion** | Automatic | Auto or Manual |

---

## Update Scenario Example

### Scenario: Update model from v1.0 to v2.0

#### Standard Mode (Rolling Update)

```bash
# Before update
Deployment: 3 pods running v1.0
Service: Routes to all 3 pods

# During update (rolling)
Deployment:
  - 2 pods running v1.0 (being terminated)
  - 1 pod running v2.0 (just started)
  - 1 pod running v2.0 (starting)
Service: Routes to mix of v1.0 and v2.0 pods

# After update
Deployment: 3 pods running v2.0
Service: Routes to all 3 pods
```

**Issues:**
- Mixed versions serving traffic simultaneously
- Possible inconsistent responses during rollout
- Brief downtime during pod replacement

---

#### ArgoRollout Mode (BlueGreen)

```bash
# Before update
Rollout: 3 pods running v1.0 (ReplicaSet-1)
Active Service: Routes to ReplicaSet-1 (v1.0)
Preview Service: No endpoints
HTTPRoute: Routes to Active Service

# During rollout (preview phase)
Rollout:
  - ReplicaSet-1: 3 pods running v1.0
  - ReplicaSet-2: 3 pods running v2.0 (NEW)
Active Service: Routes to ReplicaSet-1 (v1.0) ← Production traffic
Preview Service: Routes to ReplicaSet-2 (v2.0) ← Test traffic
HTTPRoute: Routes to Active Service (v1.0)

# Can test v2.0 via preview service!
curl -H "Host: sklearn-iris-preview.default.svc.cluster.local" http://sklearn-iris-predictor-preview/v1/models/sklearn-iris:predict

# After promotion (atomic switch)
Rollout:
  - ReplicaSet-1: 3 pods running v1.0 (to be scaled down)
  - ReplicaSet-2: 3 pods running v2.0
Active Service: Routes to ReplicaSet-2 (v2.0) ← Production traffic
Preview Service: Routes to ReplicaSet-2 (v2.0)
HTTPRoute: Routes to Active Service (v2.0)

# After scale-down delay (30s)
Rollout:
  - ReplicaSet-1: 0 pods (scaled down)
  - ReplicaSet-2: 3 pods running v2.0
Active Service: Routes to ReplicaSet-2 (v2.0)
Preview Service: No endpoints
```

**Benefits:**
- ✅ Full new version deployed before switch
- ✅ Can test new version in production environment
- ✅ Atomic traffic switch (all requests go to new version)
- ✅ Zero downtime (old version still serves during deployment)
- ✅ Easy rollback (just switch back to old ReplicaSet)
- ✅ No mixed versions serving production traffic

---

## When to Use Each Mode

### Use Standard Mode When:
- Simple deployments without strict SLA requirements
- Development/testing environments
- Cost-sensitive scenarios (fewer resources)
- Don't need pre-promotion testing
- Rolling updates are acceptable

### Use ArgoRollout Mode When:
- Production environments with strict SLA (zero downtime)
- Need to test new versions before switching traffic
- Want instant rollback capability
- Deploying critical ML models that need validation
- Using complex deployment strategies (canary, analysis)
- Need observability during deployments

---

## Resource Overhead

### Standard Mode
```
1 Deployment + 1 Service = Minimal overhead
```

### ArgoRollout Mode
```
1 Rollout + 2 Services = ~2x resources during rollout
(old + new versions both running)
After scale-down: Same as Standard Mode
```

**Note:** During BlueGreen rollout, you temporarily run 2x pods (old + new). After promotion and scale-down delay, only new version remains (same as Standard).

---

## Migration Between Modes

### Standard → ArgoRollout

```yaml
# 1. Add annotation
metadata:
  annotations:
    serving.kserve.io/deploymentMode: "ArgoRollout"  # Change from "Standard"

# 2. Apply
kubectl apply -f inferenceservice.yaml

# Result:
# - Rollout created
# - Preview service created
# - Old Deployment remains (delete manually if desired)
```

### ArgoRollout → Standard

```yaml
# 1. Change annotation
metadata:
  annotations:
    serving.kserve.io/deploymentMode: "Standard"  # Change from "ArgoRollout"

# 2. Apply
kubectl apply -f inferenceservice.yaml

# Result:
# - Deployment created
# - Old Rollout remains (delete manually if desired)
# - Preview service removed
```
