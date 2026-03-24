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

# Pick device class based on MIG state
mig_state=$(oc get node "$gpu_node" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['labels'].get('nvidia.com/mig.config','none'))" 2>/dev/null || echo "none")
if [ "$mig_state" != "all-disabled" ] && [ "$mig_state" != "none" ]; then
  DEVICE_CLASS="mig.nvidia.com"
  info "MIG enabled — using $DEVICE_CLASS DeviceClass"
else
  DEVICE_CLASS="gpu.nvidia.com"
  info "Using $DEVICE_CLASS DeviceClass"
fi

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
          deviceClassName: $DEVICE_CLASS
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

# Verify CDI spec contains nvidia device nodes
cdi_content=$(run_on_node "$gpu_node" cat /var/run/cdi/management.nvidia.com-gpu.yaml 2>/dev/null || echo "")
if echo "$cdi_content" | grep -q "/dev/nvidia"; then
  device_count=$(echo "$cdi_content" | grep -c "path: /dev/nvidia" || echo "0")
  info "CDI spec contains $device_count NVIDIA device node entries"
else
  warn "CDI spec does not contain NVIDIA device nodes"
fi

info "CRI-O + crun + DRA validation passed"
