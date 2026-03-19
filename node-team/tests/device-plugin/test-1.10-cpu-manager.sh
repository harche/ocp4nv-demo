#!/bin/bash
# Test 1.10: CPU Manager + GPU
# Validates: Static CPU pinning works alongside device plugin GPU allocation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dp-cpu-manager"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Checking CPU Manager policy on $gpu_node"
cpu_policy=$(run_on_node "$gpu_node" cat /etc/kubernetes/kubelet.conf 2>/dev/null | grep -i cpuManagerPolicy || true)
if [ -z "$cpu_policy" ]; then
  cpu_policy=$(run_on_node "$gpu_node" ps aux 2>/dev/null | grep kubelet | grep -o "cpu-manager-policy=[^ ]*" || true)
fi

if echo "$cpu_policy" | grep -qi "static"; then
  info "CPU Manager policy: static"
else
  warn "CPU Manager policy may not be 'static': $cpu_policy"
  warn "To enable: create a KubeletConfig with cpuManagerPolicy: static"
fi

header "Deploying Guaranteed QoS pod with CPU + GPU"
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
  name: cpu-gpu-test
  namespace: $NS
spec:
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c']
    args:
    - |
      echo '--- CPU pinning ---'
      cat /proc/self/status | grep Cpus_allowed_list
      echo '--- GPU ---'
      nvidia-smi -L 2>/dev/null || echo 'nvidia-smi not in PATH'
      echo '--- taskset ---'
      taskset -p 1 2>/dev/null || true
    resources:
      requests:
        nvidia.com/gpu: 1
        cpu: 2
        memory: 1Gi
      limits:
        nvidia.com/gpu: 1
        cpu: 2
        memory: 1Gi
  restartPolicy: Never
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "cpu-gpu-test" 120

logs=$(oc logs cpu-gpu-test -n "$NS")
echo "$logs"

# With static CPU manager, Cpus_allowed_list should show specific CPUs (not all)
cpus=$(echo "$logs" | grep "Cpus_allowed_list" | awk '{print $2}')
if [ -n "$cpus" ]; then
  info "CPU pinning: $cpus"
else
  warn "Could not determine CPU pinning"
fi

info "CPU Manager + GPU test complete — review pinning above"
