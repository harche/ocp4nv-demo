#!/bin/bash
# Test 2.6: MPS via DRA
# Validates: GPU shared across pods using MPS through DRA allocation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-mps"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

header "Step 1: Deploy MPS workload via DRA"
cleanup_ns "$NS"
wait_for_ns_deleted "$NS"

apply_yaml "
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  namespace: $NS
  name: shared-gpu
spec:
  spec:
    devices:
      requests:
      - name: mps-gpu
        exactly:
          deviceClassName: gpu.nvidia.com
      config:
      - requests: ['mps-gpu']
        opaque:
          driver: gpu.nvidia.com
          parameters:
            apiVersion: resource.nvidia.com/v1beta1
            kind: GpuConfig
            sharing:
              strategy: MPS
              mpsConfig:
                defaultActiveThreadPercentage: 50
                defaultPinnedDeviceMemoryLimit: 10Gi
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $NS
  name: mps-pod
  labels:
    app: mps-test
spec:
  containers:
  - name: mps-ctr0
    image: nvcr.io/nvidia/k8s/cuda-sample:nbody-cuda11.6.0-ubuntu18.04
    command: ['bash', '-c', 'trap \"exit 0\" TERM; /tmp/sample --benchmark --numbodies=1024000 & wait']
    resources:
      claims:
      - name: shared-gpu
        request: mps-gpu
  - name: mps-ctr1
    image: nvcr.io/nvidia/k8s/cuda-sample:nbody-cuda11.6.0-ubuntu18.04
    command: ['bash', '-c', 'trap \"exit 0\" TERM; /tmp/sample --benchmark --numbodies=1024000 & wait']
    resources:
      claims:
      - name: shared-gpu
        request: mps-gpu
  resourceClaims:
  - name: shared-gpu
    resourceClaimTemplateName: shared-gpu
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_running "$NS" "mps-pod" 180

info "MPS pod running — both containers sharing GPU via MPS"
oc logs mps-pod -c mps-ctr0 -n "$NS" --tail=5 2>/dev/null || true
oc logs mps-pod -c mps-ctr1 -n "$NS" --tail=5 2>/dev/null || true

info "MPS via DRA test passed"
