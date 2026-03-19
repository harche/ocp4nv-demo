#!/bin/bash
# Test 2.11: Admin access — monitoring (OCPSTRAT-2397)
# Validates: Admin pod accesses in-use GPU in labeled namespace, workload pod undisturbed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-admin"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

cleanup_ns "$NS"
wait_for_ns_deleted "$NS"

apply_yaml "
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    resource.k8s.io/admin-access: 'true'
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  namespace: $NS
  name: workload-gpu
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
  name: workload-pod
spec:
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c', 'echo workload running; trap \"exit 0\" TERM; sleep 9999 & wait']
    resources:
      claims:
      - name: gpu
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: workload-gpu
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_running "$NS" "workload-pod" 120
info "Workload pod running"

header "Deploy admin pod with adminAccess"
apply_yaml "
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
  containers:
  - name: monitor
    image: ubuntu:22.04
    command: ['bash', '-c', 'nvidia-smi; echo ADMIN_ACCESS_OK; trap \"exit 0\" TERM; sleep 9999 & wait']
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

wait_for_pod_running "$NS" "admin-pod" 120

admin_logs=$(oc logs admin-pod -n "$NS")
echo "$admin_logs"

# Verify workload pod is still running
workload_phase=$(oc get pod workload-pod -n "$NS" -o jsonpath='{.status.phase}')
if [ "$workload_phase" = "Running" ] && echo "$admin_logs" | grep -q "ADMIN_ACCESS_OK"; then
  info "Admin pod accessed GPU, workload pod undisturbed (still $workload_phase)"
else
  error "Admin access test failed (workload_phase=$workload_phase)"
  exit 1
fi
