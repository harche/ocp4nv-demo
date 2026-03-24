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
"

header "Attempting to create admin ResourceClaim (should be rejected)"

# Pick device class based on MIG state
mig_state=$(oc get node "$(get_first_gpu_node)" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['labels'].get('nvidia.com/mig.config','none'))" 2>/dev/null || echo "none")
if [ "$mig_state" != "all-disabled" ] && [ "$mig_state" != "none" ]; then
  DEVICE_CLASS="mig.nvidia.com"
else
  DEVICE_CLASS="gpu.nvidia.com"
fi

claim_output=$(oc apply -f - 2>&1 <<EOF || true
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
        deviceClassName: $DEVICE_CLASS
        adminAccess: true
EOF
)

echo "$claim_output"

if echo "$claim_output" | grep -q "admin access to devices requires"; then
  info "ResourceClaim correctly rejected — admin access forbidden in unlabeled namespace"
  info "Admin access negative test passed"
else
  # Claim was created — check if pod stays Pending
  warn "ResourceClaim was not rejected at creation — checking pod scheduling"
  apply_yaml "
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
    command: ['bash', '-c', 'echo SHOULD_NOT_RUN']
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
  sleep 30
  phase=$(oc get pod admin-pod -n "$NS" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['phase'])")
  if [ "$phase" = "Running" ] || [ "$phase" = "Succeeded" ]; then
    error "Pod is $phase — admin claim should have been rejected in unlabeled namespace"
    exit 1
  fi
  info "Pod phase: $phase — admin access blocked at scheduling"
  info "Admin access negative test passed"
fi
