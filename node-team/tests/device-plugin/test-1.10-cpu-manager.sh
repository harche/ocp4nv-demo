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
cpu_policy=$(run_on_node "$gpu_node" cat /etc/kubernetes/kubelet.conf 2>/dev/null | python3 -c "
import sys
result = ''
for line in sys.stdin:
    if 'cpuManagerPolicy' in line and not result:
        result = line.split(':',1)[1].strip()
print(result)
" 2>/dev/null || echo "")

if [ "$cpu_policy" != "static" ]; then
  info "SKIP: cpuManagerPolicy is '$cpu_policy', not 'static'"
  info "To enable: create a KubeletConfig with cpuManagerPolicy: static"
  exit 2
fi
info "CPU Manager policy: $cpu_policy"

header "Deploy guaranteed QoS pod with CPU + GPU"
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
    command: ['sleep', '9999']
    resources:
      requests:
        nvidia.com/gpu: 1
        cpu: 2
        memory: 1Gi
      limits:
        nvidia.com/gpu: 1
        cpu: 2
        memory: 1Gi
  restartPolicy: Always
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_running "$NS" "cpu-gpu-test" 120

header "Verifying CPU pinning"

# Get CPU info from container
proc_status=$(oc exec cpu-gpu-test -n "$NS" -- cat /proc/self/status 2>/dev/null)
cpu_list=$(echo "$proc_status" | python3 -c "
import sys
for line in sys.stdin:
    if line.startswith('Cpus_allowed_list'):
        print(line.split(':',1)[1].strip())
        break
")

# Get GPU UUID to confirm GPU was allocated
gpu_uuid=$(oc exec cpu-gpu-test -n "$NS" -- nvidia-smi --query-gpu=uuid --format=csv,noheader,nounits 2>/dev/null | tr -d '[:space:]')

total_cpus=$(oc get node "$gpu_node" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['capacity']['cpu'])")

info "Pinned CPUs: $cpu_list (requested 2, node has $total_cpus)"
info "GPU UUID: $gpu_uuid"

# Assert 1: CPU pinning — must be a strict subset of all CPUs
if [ "$cpu_list" = "0-$((total_cpus-1))" ]; then
  error "CPU not pinned — got all CPUs ($cpu_list). cpuManagerPolicy: static not working."
  exit 1
fi

# Assert 2: Should have exactly 2 CPUs pinned (we requested cpu: 2)
pinned_count=$(echo "$cpu_list" | python3 -c "
import sys
s = sys.stdin.read().strip()
count = 0
for part in s.split(','):
    if '-' in part:
        lo, hi = part.split('-')
        count += int(hi) - int(lo) + 1
    else:
        count += 1
print(count)
")
if [ "$pinned_count" -ne 2 ]; then
  error "Expected 2 pinned CPUs, got $pinned_count ($cpu_list)"
  exit 1
fi
info "CPU pinning verified: $pinned_count CPUs pinned ($cpu_list)"

# Assert 3: GPU must be allocated
if [ -z "$gpu_uuid" ]; then
  error "No GPU UUID found — GPU not allocated"
  exit 1
fi
info "GPU allocated ($gpu_uuid)"

info "CPU Manager test passed — 2 CPUs pinned ($cpu_list), GPU allocated, guaranteed QoS"
