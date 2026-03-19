#!/bin/bash
# Test 1.2: Basic GPU workload
# Validates: Pod with nvidia.com/gpu: 1 runs vectorAdd successfully
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dp-basic-gpu"
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
apiVersion: v1
kind: Pod
metadata:
  name: vectoradd
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.6.0
    resources:
      requests:
        nvidia.com/gpu: 1
      limits:
        nvidia.com/gpu: 1
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "vectoradd" 120

logs=$(oc logs vectoradd -n "$NS")
echo "$logs"

if echo "$logs" | grep -qi "test passed"; then
  info "vectorAdd test passed"
else
  error "vectorAdd did not report 'Test PASSED'"
  exit 1
fi
