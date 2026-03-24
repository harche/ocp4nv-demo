#!/bin/bash
# Test 2.4: Device sharing between containers
# Validates: Two containers share one ResourceClaim, same GPU UUID visible in both
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-sharing"
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
  name: shared-gpu-pod
spec:
  containers:
  - name: ctr0
    image: ubuntu:22.04
    command: ['bash', '-c', 'nvidia-smi --query-gpu=uuid --format=csv,noheader > /tmp/gpu-uuid; trap \"exit 0\" TERM; sleep 9999 & wait']
    resources:
      claims:
      - name: shared-gpu
  - name: ctr1
    image: ubuntu:22.04
    command: ['bash', '-c', 'nvidia-smi --query-gpu=uuid --format=csv,noheader > /tmp/gpu-uuid; trap \"exit 0\" TERM; sleep 9999 & wait']
    resources:
      claims:
      - name: shared-gpu
  resourceClaims:
  - name: shared-gpu
    resourceClaimTemplateName: single-gpu
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_running "$NS" "shared-gpu-pod" 120

header "Checking GPU UUID in both containers"
uuid0=$(oc exec shared-gpu-pod -c ctr0 -n "$NS" -- cat /tmp/gpu-uuid | tr -d '[:space:]')
uuid1=$(oc exec shared-gpu-pod -c ctr1 -n "$NS" -- cat /tmp/gpu-uuid | tr -d '[:space:]')

info "Container ctr0 GPU UUID: $uuid0"
info "Container ctr1 GPU UUID: $uuid1"

if [ -n "$uuid0" ] && [ "$uuid0" = "$uuid1" ]; then
  info "Both containers share the same GPU (UUID match)"
else
  error "GPU UUIDs don't match or are empty"
  exit 1
fi
