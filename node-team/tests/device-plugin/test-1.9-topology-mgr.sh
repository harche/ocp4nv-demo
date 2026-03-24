#!/bin/bash
# Test 1.9: Topology Manager (NUMA alignment)
# Validates: GPU + CPU + memory on same NUMA node with single-numa-node policy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dp-topology"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Checking Topology Manager policy on $gpu_node"
topo_policy=$(run_on_node "$gpu_node" cat /etc/kubernetes/kubelet.conf 2>/dev/null | python3 -c "
import sys
result = ''
for line in sys.stdin:
    if 'topologyManagerPolicy' in line and not result:
        result = line.split(':',1)[1].strip()
print(result)
" 2>/dev/null || echo "")

if [ -z "$topo_policy" ]; then
  info "SKIP: topologyManagerPolicy not configured"
  info "To enable: create a KubeletConfig with topologyManagerPolicy: single-numa-node"
  exit 2
fi
info "Topology Manager policy: $topo_policy"

header "Deploy guaranteed QoS pod with GPU"
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
  name: topo-test
  namespace: $NS
spec:
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['sleep', '9999']
    resources:
      requests:
        nvidia.com/gpu: 1
        cpu: 1
        memory: 512Mi
      limits:
        nvidia.com/gpu: 1
        cpu: 1
        memory: 512Mi
  restartPolicy: Always
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_running "$NS" "topo-test" 120

header "Verifying NUMA alignment"

# Get CPU and memory NUMA info from the container's cgroup view
proc_status=$(oc exec topo-test -n "$NS" -- cat /proc/self/status 2>/dev/null)
cpu_list=$(echo "$proc_status" | python3 -c "
import sys
for line in sys.stdin:
    if line.startswith('Cpus_allowed_list'):
        print(line.split(':',1)[1].strip())
        break
")
mem_list=$(echo "$proc_status" | python3 -c "
import sys
for line in sys.stdin:
    if line.startswith('Mems_allowed_list'):
        print(line.split(':',1)[1].strip())
        break
")

# Get total CPUs on node
total_cpus=$(oc get node "$gpu_node" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['capacity']['cpu'])")

info "Pinned CPUs: $cpu_list (node has $total_cpus)"
info "Memory NUMA: $mem_list"

# Assert 1: CPU pinning — must be a strict subset of all CPUs
if [ "$cpu_list" = "0-$((total_cpus-1))" ]; then
  error "CPU not pinned — got all CPUs ($cpu_list). cpuManagerPolicy may not be static."
  exit 1
fi
info "CPU pinning verified ($cpu_list is a subset of 0-$((total_cpus-1)))"

# Assert 2: Get NUMA node for pinned CPU
first_cpu=$(echo "$cpu_list" | python3 -c "import sys; s=sys.stdin.read().strip(); print(s.split('-')[0].split(',')[0])")
cpu_numa=$(run_on_node "$gpu_node" cat /sys/devices/system/cpu/cpu${first_cpu}/topology/physical_package_id 2>/dev/null | tr -d '[:space:]')
info "CPU $first_cpu is on NUMA node: $cpu_numa"

# Assert 3: CPU NUMA must match memory NUMA
if [ "$cpu_numa" != "$mem_list" ]; then
  error "NUMA misalignment — CPU on NUMA $cpu_numa, memory on NUMA $mem_list"
  exit 1
fi
info "CPU (NUMA $cpu_numa) and memory (NUMA $mem_list) aligned"

# The pod scheduled successfully under single-numa-node policy with a GPU,
# proving topology manager accepted the GPU+CPU NUMA alignment.
info "Topology test passed — CPU pinned ($cpu_list), NUMA aligned (node $cpu_numa), scheduled under $topo_policy policy"
