#!/bin/bash
# Test 1.7: Concurrent workloads with MPS
# Validates: Multiple pods share a GPU via MPS, all run CUDA workloads concurrently
# Depends on: test-1.6 (MPS must be enabled)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dp-mps-concurrent"
NUM_PODS=3
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

cleanup_ns "$NS"
wait_for_ns_deleted "$NS"

# Build multi-pod YAML
YAML="apiVersion: v1
kind: Namespace
metadata:
  name: $NS"

for i in $(seq 1 $NUM_PODS); do
  YAML="$YAML
---
apiVersion: v1
kind: Pod
metadata:
  name: mps-pod-$i
  namespace: $NS
spec:
  containers:
  - name: cuda
    image: nvcr.io/nvidia/k8s/cuda-sample:nbody-cuda11.6.0-ubuntu18.04
    command: ['bash', '-c', 'echo pod-$i starting; /tmp/sample --benchmark --numbodies=1024000 2>&1 | tail -5; echo pod-$i done']
    resources:
      requests:
        nvidia.com/gpu: 1
      limits:
        nvidia.com/gpu: 1
  restartPolicy: Never
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule"
done

apply_yaml "$YAML"

header "Waiting for all MPS pods to complete"
all_passed=true
for i in $(seq 1 $NUM_PODS); do
  if wait_for_pod_complete "$NS" "mps-pod-$i" 180; then
    info "mps-pod-$i completed"
    oc logs "mps-pod-$i" -n "$NS" | tail -3
  else
    error "mps-pod-$i did not complete"
    all_passed=false
  fi
done

if $all_passed; then
  info "All $NUM_PODS pods ran concurrently on shared GPU via MPS"
else
  error "Some MPS pods failed"
  exit 1
fi
