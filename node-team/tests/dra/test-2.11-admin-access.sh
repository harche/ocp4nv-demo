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

DEVICE_CLASS="gpu.nvidia.com"

apply_yaml "
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    resource.kubernetes.io/admin-access: 'true'
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
          deviceClassName: $DEVICE_CLASS
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
    command: ['bash', '-c', 'nvidia-smi --query-gpu=uuid --format=csv,noheader,nounits > /tmp/gpu-uuid; trap \"exit 0\" TERM; sleep 9999 & wait']
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
        deviceClassName: $DEVICE_CLASS
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
    command: ['bash', '-c', 'nvidia-smi --query-gpu=uuid --format=csv,noheader,nounits > /tmp/gpu-uuid; trap \"exit 0\" TERM; sleep 9999 & wait']
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

header "Verifying GPU UUID match and workload pod health"

workload_uuid=$(oc exec workload-pod -n "$NS" -- cat /tmp/gpu-uuid | tr -d '[:space:]')
admin_uuid=$(oc exec admin-pod -n "$NS" -- cat /tmp/gpu-uuid | tr -d '[:space:]')
workload_phase=$(oc get pod workload-pod -n "$NS" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['phase'])")

info "Workload pod GPU UUID: $workload_uuid"
info "Admin pod GPU UUID:    $admin_uuid"
info "Workload pod phase:    $workload_phase"

if [ -z "$workload_uuid" ] || [ -z "$admin_uuid" ]; then
  error "Could not retrieve GPU UUID from one or both pods"
  exit 1
fi

if [ "$workload_uuid" != "$admin_uuid" ]; then
  error "GPU UUIDs do not match — admin pod did not access the same GPU"
  exit 1
fi

if [ "$workload_phase" != "Running" ]; then
  error "Workload pod is $workload_phase — expected Running"
  exit 1
fi

info "Admin pod accessed same GPU (UUID match), workload pod undisturbed"
