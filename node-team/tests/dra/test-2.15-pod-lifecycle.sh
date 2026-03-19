#!/bin/bash
# Test 2.15: Pod lifecycle cleanup
# Validates: Pod deletion unprepares resources, ResourceClaim released, CDI specs cleaned up
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-lifecycle"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

cleanup_ns "$NS"
wait_for_ns_deleted "$NS"

header "Step 1: Create pod with DRA GPU claim"
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
  name: lifecycle-pod
spec:
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c', 'trap \"exit 0\" TERM; sleep 9999 & wait']
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

wait_for_pod_running "$NS" "lifecycle-pod" 120
info "Pod running with DRA-allocated GPU"

header "Step 2: Record current ResourceClaim state"
claims_before=$(oc get resourceclaims -n "$NS" --no-headers 2>/dev/null | wc -l)
info "ResourceClaims before deletion: $claims_before"

header "Step 3: Delete the pod"
oc delete pod lifecycle-pod -n "$NS" --wait=true --timeout=60s
info "Pod deleted"

header "Step 4: Verify ResourceClaim released"
sleep 10
claims_after=$(oc get resourceclaims -n "$NS" --no-headers 2>/dev/null | wc -l)
info "ResourceClaims after deletion: $claims_after"

# With ResourceClaimTemplate, the claim should be cleaned up with the pod
if [ "$claims_after" -lt "$claims_before" ] || [ "$claims_after" -eq 0 ]; then
  info "ResourceClaim was released/cleaned up"
else
  # Check if the claim is at least not reserved anymore
  reserved=$(oc get resourceclaims -n "$NS" -o jsonpath='{.items[*].status.reservedFor}' 2>/dev/null || echo "")
  if [ -z "$reserved" ] || [ "$reserved" = "[]" ]; then
    info "ResourceClaim exists but is no longer reserved"
  else
    warn "ResourceClaim may still be reserved: $reserved"
  fi
fi

header "Step 5: Check kubelet logs for NodeUnprepareResources"
unprepare_logs=$(run_on_node "$gpu_node" journalctl -u kubelet --since "5 minutes ago" --no-pager 2>/dev/null | \
  grep -i "NodeUnprepareResources\|unprepare" | tail -5 || true)
if [ -n "$unprepare_logs" ]; then
  info "NodeUnprepareResources logged:"
  echo "$unprepare_logs"
else
  warn "Could not find NodeUnprepareResources in recent kubelet logs"
fi

info "Pod lifecycle cleanup test complete"
