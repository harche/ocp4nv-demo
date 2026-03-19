#!/bin/bash
# Test 2.12: Admin access — negative test (OCPSTRAT-2397)
# Validates: Admin claim in namespace WITHOUT admin-access label is rejected
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-admin-neg"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

cleanup_ns "$NS"
wait_for_ns_deleted "$NS"

# Namespace WITHOUT the admin-access label
apply_yaml "
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  namespace: $NS
  name: admin-gpu
spec:
  devices:
    requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.nvidia.com
        adminAccess: true
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $NS
  name: admin-pod
spec:
  restartPolicy: Never
  containers:
  - name: monitor
    image: ubuntu:22.04
    command: ['bash', '-c', 'nvidia-smi; echo SHOULD_NOT_RUN']
    resources:
      claims:
      - name: admin-gpu
  resourceClaims:
  - name: admin-gpu
    resourceClaimName: admin-gpu
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

header "Waiting to verify admin claim is rejected"
sleep 30

phase=$(oc get pod admin-pod -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")

if [ "$phase" = "Pending" ]; then
  info "Pod correctly stays Pending — admin access rejected in unlabeled namespace"

  events=$(oc get events -n "$NS" --field-selector involvedObject.name=admin-pod -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for e in data.get('items', []):
    msg = e.get('message', '')
    reason = e.get('reason', '')
    if msg:
        print(f'  [{reason}] {msg}')
" 2>/dev/null || true)
  if [ -n "$events" ]; then
    echo "$events"
  fi
elif [ "$phase" = "Running" ] || [ "$phase" = "Succeeded" ]; then
  error "Pod is $phase — admin claim should have been rejected in unlabeled namespace"
  exit 1
else
  # Could be FailedScheduling or similar — still a pass
  info "Pod phase: $phase — admin access appears to be blocked"
fi

info "Admin access negative test passed"
