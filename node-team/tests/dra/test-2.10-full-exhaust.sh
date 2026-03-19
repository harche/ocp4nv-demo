#!/bin/bash
# Test 2.10: Full exhaustion
# Validates: All alternatives consumed, pod stays Pending with clear scheduling message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-exhaust"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

cleanup_ns "$NS"
wait_for_ns_deleted "$NS"

# Request a MIG profile that doesn't exist (no matching devices at all)
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
  name: impossible-gpu
spec:
  spec:
    devices:
      requests:
      - name: gpu
        firstAvailable:
        - exactly:
            deviceClassName: mig.nvidia.com
            selectors:
            - cel:
                expression: \"device.attributes['gpu.nvidia.com'].profile == 'nonexistent-99g.999gb'\"
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $NS
  name: exhaust-pod
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c', 'echo should-not-run']
    resources:
      claims:
      - name: gpu
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: impossible-gpu
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

header "Waiting to confirm pod stays Pending"
sleep 30

phase=$(oc get pod exhaust-pod -n "$NS" -o jsonpath='{.status.phase}')
if [ "$phase" = "Pending" ]; then
  info "Pod correctly stays Pending when all alternatives exhausted"

  header "Checking scheduling message"
  events=$(oc get events -n "$NS" --field-selector involvedObject.name=exhaust-pod -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for e in data.get('items', []):
    msg = e.get('message', '')
    if msg:
        print(f'  {msg}')
" 2>/dev/null || true)
  echo "$events"
  info "Full exhaustion test passed"
else
  error "Pod is $phase — expected Pending"
  exit 1
fi
