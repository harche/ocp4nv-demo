#!/bin/bash
# Test 1.5: MIG workload
# Validates: Pod requesting a MIG slice runs CUDA workload successfully
# Depends on: test-1.4 (MIG must be enabled)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dp-mig-workload"
MIG_RESOURCE="${MIG_RESOURCE:-nvidia.com/mig-1g.5gb}"
MIG_PROFILE_SMALL="${MIG_PROFILE_SMALL:-1g.5gb}"

check_cdmm_mig_compatible

cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

# Verify MIG resources exist
gpu_node=$(get_first_gpu_node)
mig_count=$(oc get node "$gpu_node" -o json | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',{}).get('allocatable',{}).get('nvidia.com/mig-${MIG_PROFILE_SMALL}','0'))" 2>/dev/null || echo "0")
if [ "$mig_count" = "0" ] || [ -z "$mig_count" ]; then
  error "No $MIG_RESOURCE available on $gpu_node. Run test-1.4 first."
  exit 1
fi
info "Found $mig_count $MIG_RESOURCE on $gpu_node"

cleanup_ns "$NS"
wait_for_ns_deleted "$NS"

apply_yaml "
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: v1
kind: Pod
metadata:
  name: mig-workload
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.6.0
    resources:
      requests:
        $MIG_RESOURCE: 1
      limits:
        $MIG_RESOURCE: 1
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "mig-workload" 120

logs=$(oc logs mig-workload -n "$NS")
echo "$logs"

if echo "$logs" | grep -qi "test passed"; then
  info "MIG workload passed"
else
  error "MIG workload did not report success"
  exit 1
fi
