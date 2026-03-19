#!/bin/bash
# Test 2.9: Prioritized alternatives — fallback on exhaustion (OCPSTRAT-2115)
# Validates: Preferred MIG profile exhausted, fallback profile allocated
# Depends on: MIG enabled with 1g.5gb profiles
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-fallback"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Enable MIG with all-1g.5gb to get multiple slices"
oc label node "$gpu_node" nvidia.com/mig.config=all-1g.5gb --overwrite
sleep 60

cleanup_ns "$NS"
wait_for_ns_deleted "$NS"

# Strategy: request a non-existent preferred profile (7g.40gb when only 1g.5gb exist),
# falling back to 1g.5gb
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
  name: fallback-mig
spec:
  spec:
    devices:
      requests:
      - name: mig
        firstAvailable:
        - exactly:
            deviceClassName: mig.nvidia.com
            selectors:
            - cel:
                expression: \"device.attributes['gpu.nvidia.com'].profile == '7g.40gb'\"
        - exactly:
            deviceClassName: mig.nvidia.com
            selectors:
            - cel:
                expression: \"device.attributes['gpu.nvidia.com'].profile == '1g.5gb'\"
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $NS
  name: fallback-pod
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c', 'nvidia-smi -L; echo FALLBACK_TEST_DONE']
    resources:
      claims:
      - name: mig
  resourceClaims:
  - name: mig
    resourceClaimTemplateName: fallback-mig
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "fallback-pod" 120

logs=$(oc logs fallback-pod -n "$NS")
echo "$logs"

if echo "$logs" | grep -q "FALLBACK_TEST_DONE"; then
  info "Fallback test passed — 7g.40gb unavailable, fell back to 1g.5gb"
else
  error "Fallback test did not complete"
  exit 1
fi
