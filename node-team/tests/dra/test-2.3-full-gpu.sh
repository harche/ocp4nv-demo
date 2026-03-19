#!/bin/bash
# Test 2.3: ResourceClaim for full GPU
# Validates: CEL selector matches GPU, pod runs vectorAdd via DRA allocation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-full-gpu"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

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
  name: single-gpu
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $NS
  name: gpu-pod
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.6.0
    resources:
      claims:
      - name: gpu
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: single-gpu
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "gpu-pod" 120

logs=$(oc logs gpu-pod -n "$NS")
echo "$logs"

if echo "$logs" | grep -qi "test passed"; then
  info "DRA full GPU allocation + vectorAdd passed"
else
  error "vectorAdd did not report success via DRA"
  exit 1
fi
