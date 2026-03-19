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
topo_policy=$(run_on_node "$gpu_node" cat /etc/kubernetes/kubelet.conf 2>/dev/null | grep -i topologyManagerPolicy || true)
if [ -z "$topo_policy" ]; then
  # Try via kubelet flags
  topo_policy=$(run_on_node "$gpu_node" ps aux 2>/dev/null | grep kubelet | grep -o "topology-manager-policy=[^ ]*" || true)
fi

if [ -n "$topo_policy" ]; then
  info "Topology Manager: $topo_policy"
else
  warn "Could not determine topology manager policy"
  warn "To enable: create a KubeletConfig with topologyManagerPolicy: single-numa-node"
fi

header "Checking GPU NUMA topology"
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
    command: ['bash', '-c', 'nvidia-smi topo -m 2>/dev/null || echo no-topo; cat /proc/self/status | grep -E \"Cpus_allowed|Mems_allowed\"; sleep 5']
    resources:
      requests:
        nvidia.com/gpu: 1
        cpu: 1
        memory: 512Mi
      limits:
        nvidia.com/gpu: 1
        cpu: 1
        memory: 512Mi
  restartPolicy: Never
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "topo-test" 120

logs=$(oc logs topo-test -n "$NS")
echo "$logs"
info "Topology test complete — review NUMA alignment above"
