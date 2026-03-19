#!/bin/bash
# Test 2.8: Prioritized alternatives — preferred device selected (OCPSTRAT-2115)
# Validates: firstAvailable picks preferred MIG profile
# Depends on: MIG must be enabled
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-preferred"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Ensure MIG is enabled"
# Use a mixed profile so we have both 3g.20gb and 1g.5gb
oc label node "$gpu_node" nvidia.com/mig.config=all-balanced --overwrite 2>/dev/null || \
  oc label node "$gpu_node" nvidia.com/mig.config=all-1g.5gb --overwrite
sleep 60

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
  name: preferred-mig
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
                expression: \"device.attributes['gpu.nvidia.com'].profile == '3g.20gb'\"
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
  name: preferred-pod
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c', 'nvidia-smi -L; echo PREFERRED_TEST_DONE']
    resources:
      claims:
      - name: mig
  resourceClaims:
  - name: mig
    resourceClaimTemplateName: preferred-mig
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "preferred-pod" 120

logs=$(oc logs preferred-pod -n "$NS")
echo "$logs"

if echo "$logs" | grep -q "PREFERRED_TEST_DONE"; then
  info "Prioritized alternatives (firstAvailable) test passed"
  info "Pod was allocated a MIG profile via firstAvailable preference"
else
  error "Preferred device test did not complete"
  exit 1
fi
