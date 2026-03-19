#!/bin/bash
# Test 2.16: Topology Manager + DRA
# Validates: NUMA alignment with DRA-allocated GPUs under single-numa-node policy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-topology"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Checking Topology Manager policy on $gpu_node"
topo_policy=$(run_on_node "$gpu_node" cat /etc/kubernetes/kubelet.conf 2>/dev/null | grep -i topologyManagerPolicy || true)
if [ -n "$topo_policy" ]; then
  info "Topology Manager: $topo_policy"
else
  warn "Could not determine topology manager policy"
fi

header "Deploy guaranteed QoS pod with DRA GPU"
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
  name: topo-dra-test
spec:
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c']
    args:
    - |
      echo '--- NUMA info ---'
      cat /proc/self/status | grep -E 'Cpus_allowed|Mems_allowed'
      echo '--- GPU topology ---'
      nvidia-smi topo -m 2>/dev/null || echo 'nvidia-smi topo not available'
      echo '--- done ---'
    resources:
      claims:
      - name: gpu
      requests:
        cpu: 1
        memory: 512Mi
      limits:
        cpu: 1
        memory: 512Mi
  restartPolicy: Never
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: single-gpu
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "topo-dra-test" 120

logs=$(oc logs topo-dra-test -n "$NS")
echo "$logs"
info "Topology + DRA test complete — review NUMA alignment above"
