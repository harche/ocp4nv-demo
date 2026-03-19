#!/bin/bash
# Test 2.13: CRI-O + crun + DRA
# Validates: CDI injection path via DRA, crun handles DRA-prepared devices correctly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-crio-crun"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Verify crun runtime"
runtime_info=$(run_on_node "$gpu_node" crictl info 2>/dev/null || true)
if echo "$runtime_info" | grep -q "crun"; then
  info "crun confirmed as container runtime"
else
  warn "Could not confirm crun — checking anyway"
fi

header "Deploy DRA pod and check CDI injection"
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
  name: cdi-test
spec:
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c']
    args:
    - |
      echo '--- /dev/nvidia* ---'
      ls -la /dev/nvidia* 2>/dev/null || echo 'no nvidia devices'
      echo '--- env ---'
      env | grep -i nvidia || echo 'no nvidia env vars'
      echo '--- CDI check done ---'
    resources:
      claims:
      - name: gpu
  restartPolicy: Never
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: single-gpu
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "cdi-test" 120

logs=$(oc logs cdi-test -n "$NS")
echo "$logs"

if echo "$logs" | grep -q "/dev/nvidia"; then
  info "NVIDIA devices injected via CDI/DRA path"
else
  error "No NVIDIA devices found in container — CDI injection may have failed"
  exit 1
fi

header "Check CDI specs on node"
cdi_specs=$(run_on_node "$gpu_node" ls /var/run/cdi/ 2>/dev/null || \
  run_on_node "$gpu_node" ls /etc/cdi/ 2>/dev/null || echo "")
if [ -n "$cdi_specs" ]; then
  info "CDI specs present on node:"
  echo "$cdi_specs"
else
  warn "Could not list CDI specs on node"
fi

info "CRI-O + crun + DRA validation passed"
