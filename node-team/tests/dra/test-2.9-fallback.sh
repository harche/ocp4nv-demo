#!/bin/bash
# Test 2.9: Prioritized alternatives — fallback on exhaustion (OCPSTRAT-2115)
# Validates: Preferred MIG profile exhausted, fallback profile allocated
# Depends on: MIG enabled with 1g.5gb profiles
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-fallback"
MIG_PROFILE_SMALL="${MIG_PROFILE_SMALL:-1g.5gb}"
MIG_PROFILE_LARGE="${MIG_PROFILE_LARGE:-7g.40gb}"
MIG_PROFILE="${MIG_PROFILE:-all-1g.5gb}"

check_cdmm_mig_compatible

cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Ensure MIG is enabled"
mig_state=$(oc get node "$gpu_node" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['labels'].get('nvidia.com/mig.config','none'))" 2>/dev/null || echo "none")
if [ "$mig_state" = "$MIG_PROFILE" ]; then
  info "MIG already enabled ($mig_state) — skipping"
else
  info "MIG is '$mig_state' — enabling $MIG_PROFILE (will reboot)..."
  oc label node "$gpu_node" nvidia.com/mig.config="$MIG_PROFILE" --overwrite
  wait_for_nodes_ready 600
  sleep 30
  oc delete pods -n nvidia-dra-driver-gpu --all 2>/dev/null || true
  sleep 30
fi

cleanup_ns "$NS"
wait_for_ns_deleted "$NS"

# Strategy: request a non-existent preferred profile (large when only small exist),
# falling back to MIG_PROFILE_SMALL
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
        - name: large
          deviceClassName: mig.nvidia.com
          selectors:
          - cel:
              expression: \"device.attributes['gpu.nvidia.com'].profile == '$MIG_PROFILE_LARGE'\"
        - name: small
          deviceClassName: mig.nvidia.com
          selectors:
          - cel:
              expression: \"device.attributes['gpu.nvidia.com'].profile == '$MIG_PROFILE_SMALL'\"
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
    command: ['bash', '-c', 'nvidia-smi --query-gpu=uuid,name --format=csv,noheader,nounits; echo FALLBACK_TEST_DONE']
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
  info "Fallback test passed — $MIG_PROFILE_LARGE unavailable, fell back to $MIG_PROFILE_SMALL"
else
  error "Fallback test did not complete"
  exit 1
fi
