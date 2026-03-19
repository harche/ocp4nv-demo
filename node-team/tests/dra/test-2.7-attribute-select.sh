#!/bin/bash
# Test 2.7: Attribute-based GPU allocation (OCPSTRAT-2384)
# Validates: Claim filtering by productName allocates correct device
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-attr-select"
# Default to A100; override with GPU_PRODUCT_PATTERN for other hardware
GPU_PRODUCT_PATTERN="${GPU_PRODUCT_PATTERN:-a100}"
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
  name: specific-gpu
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          selectors:
          - cel:
              expression: |
                device.attributes['gpu.nvidia.com'].productName.lowerAscii().matches('^.*${GPU_PRODUCT_PATTERN}.*\$')
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $NS
  name: attr-pod
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c', 'nvidia-smi -L; nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true']
    resources:
      claims:
      - name: gpu
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: specific-gpu
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "attr-pod" 120

logs=$(oc logs attr-pod -n "$NS")
echo "$logs"

if echo "$logs" | grep -qi "$GPU_PRODUCT_PATTERN"; then
  info "Attribute-based selection matched: $GPU_PRODUCT_PATTERN"
else
  error "GPU product name does not match pattern '$GPU_PRODUCT_PATTERN'"
  exit 1
fi
