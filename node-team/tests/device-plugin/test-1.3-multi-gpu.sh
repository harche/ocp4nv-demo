#!/bin/bash
# Test 1.3: Multi-GPU pod
# Validates: Pod with nvidia.com/gpu: 2 sees exactly 2 GPUs
# Requires: a2-highgpu-2g or larger instance type
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dp-multi-gpu"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

# Check if any node has >= 2 GPUs
gpu_node=$(get_first_gpu_node)
gpu_count=$(get_gpu_count "$gpu_node")
if [ "$gpu_count" -lt 2 ]; then
  warn "Node $gpu_node has only $gpu_count GPU(s), need 2+. Skipping test."
  warn "Use a2-highgpu-2g or larger instance type for this test."
  exit 2
fi

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
  name: multi-gpu
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c', 'nvidia-smi -L; echo GPU_COUNT=\$(nvidia-smi -L | wc -l)']
    resources:
      requests:
        nvidia.com/gpu: 2
      limits:
        nvidia.com/gpu: 2
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "multi-gpu" 120

logs=$(oc logs multi-gpu -n "$NS")
echo "$logs"

reported_count=$(echo "$logs" | grep "GPU_COUNT=" | sed 's/GPU_COUNT=//')
if [ "$reported_count" -eq 2 ]; then
  info "Pod sees exactly 2 GPUs"
else
  error "Expected 2 GPUs, got: $reported_count"
  exit 1
fi
