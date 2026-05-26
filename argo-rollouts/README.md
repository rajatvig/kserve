# Argo Rollouts Integration Resources

This directory contains reference documentation and test infrastructure for Argo Rollouts integration with KServe.

## Main Documentation

See root-level documents:
- `Argo Rollout Support in Kserve.md` - Community proposal document
- `Argo Rollout Implementation Plan.md` - Implementation task breakdown

## Directory Structure

```
argo-rollouts/
├── docs/
│   ├── ARGO_ROLLOUT_INVESTIGATION.md   # Architecture analysis and findings
│   └── TESTING_PLAN.md                  # Test scenarios and verification
├── examples/
│   └── comparison.md                    # Standard vs ArgoRollout mode comparison
└── tests/
    ├── README.md                        # Test suite usage guide
    ├── common.sh                        # Shared test utilities
    ├── 01-setup-cluster.sh             # Create kind cluster
    ├── 02-install-components.sh        # Install Gateway API, Argo Rollouts, KServe
    ├── 03-test-standard-deployment.sh  # Baseline test (no rollout)
    ├── 04-test-rollout-deployment.sh   # Rollout test (pending implementation)
    ├── 99-cleanup.sh                   # Cleanup cluster
    └── manifests/                       # Test YAML manifests
```

## Quick Start (Testing)

```bash
cd tests
./01-setup-cluster.sh
./02-install-components.sh
./03-test-standard-deployment.sh
./99-cleanup.sh
```

## Reference

- `docs/ARGO_ROLLOUT_INVESTIGATION.md` - Multi-node Ray architecture analysis, service topology, design decisions
- `docs/TESTING_PLAN.md` - Detailed test scenarios and verification checklist
- `examples/comparison.md` - Side-by-side comparison of Standard vs ArgoRollout modes
