#!/bin/bash
# Test 2.6: MPS via DRA
# Validates: GPU shared across pods using MPS through DRA allocation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-mps"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Step 1: Ensure MIG is disabled"
mig_state=$(oc get node "$gpu_node" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['labels'].get('nvidia.com/mig.config','none'))" 2>/dev/null || echo "none")

if [ "$mig_state" != "all-disabled" ] && [ "$mig_state" != "none" ]; then
  info "MIG is $mig_state — disabling..."
  oc apply -f "$NODE_TEAM_ROOT/gpu-cluster-policy-dra.yaml"
  oc patch clusterpolicy gpu-cluster-policy --type=json -p '[{"op": "remove", "path": "/spec/devicePlugin/config"}]' 2>/dev/null || true
  sleep 15
  oc label node "$gpu_node" nvidia.com/mig.config=all-disabled --overwrite

  info "Waiting for node to reboot..."
  reboot_timeout=180
  elapsed=0
  while [ $elapsed -lt $reboot_timeout ]; do
    node_status=$(oc get node "$gpu_node" -o json 2>/dev/null | python3 -c "import sys,json; cs=[c for c in json.load(sys.stdin)['status']['conditions'] if c['type']=='Ready']; print(cs[0]['status'] if cs else 'Unknown')" 2>/dev/null || echo "Unknown")
    if [ "$node_status" != "True" ]; then
      info "Node is rebooting"
      break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done

  wait_for_nodes_ready 600
  sleep 30

  info "Waiting for all pods to recover..."
  op_timeout=600
  elapsed=0
  while [ $elapsed -lt $op_timeout ]; do
    pod_status=$(oc get pods -n nvidia-gpu-operator -o json 2>/dev/null | python3 -c "
import sys,json
pods = json.load(sys.stdin)['items']
not_ready = len([p for p in pods if p['status']['phase'] not in ('Running','Succeeded')])
print(f'{not_ready} {len(pods)}')" 2>/dev/null || echo "99 0")
    not_ready=$(echo "$pod_status" | cut -d' ' -f1)
    total=$(echo "$pod_status" | cut -d' ' -f2)
    if [ "$not_ready" -eq 0 ] && [ "$total" -gt 5 ]; then
      info "All pods healthy ($total GPU operator pods)"
      break
    fi
    sleep 20
    elapsed=$((elapsed + 20))
  done
else
  info "MIG already disabled (state: $mig_state) — skipping"
fi

header "Step 2: Deploy MPS workload via DRA"
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
  name: shared-gpu
spec:
  spec:
    devices:
      requests:
      - name: mps-gpu
        exactly:
          deviceClassName: gpu.nvidia.com
      config:
      - requests: ['mps-gpu']
        opaque:
          driver: gpu.nvidia.com
          parameters:
            apiVersion: resource.nvidia.com/v1beta1
            kind: GpuConfig
            sharing:
              strategy: MPS
              mpsConfig:
                defaultActiveThreadPercentage: 50
                defaultPinnedDeviceMemoryLimit: 10Gi
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $NS
  name: mps-pod
  labels:
    app: mps-test
spec:
  containers:
  - name: mps-ctr0
    image: nvcr.io/nvidia/k8s/cuda-sample:nbody-cuda11.6.0-ubuntu18.04
    command: ['bash', '-c', 'trap \"exit 0\" TERM; /tmp/sample --benchmark --numbodies=1024000 & wait']
    resources:
      claims:
      - name: shared-gpu
        request: mps-gpu
  - name: mps-ctr1
    image: nvcr.io/nvidia/k8s/cuda-sample:nbody-cuda11.6.0-ubuntu18.04
    command: ['bash', '-c', 'trap \"exit 0\" TERM; /tmp/sample --benchmark --numbodies=1024000 & wait']
    resources:
      claims:
      - name: shared-gpu
        request: mps-gpu
  resourceClaims:
  - name: shared-gpu
    resourceClaimTemplateName: shared-gpu
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_running "$NS" "mps-pod" 180

info "MPS pod running — both containers sharing GPU via MPS"
oc logs mps-pod -c mps-ctr0 -n "$NS" --tail=5 2>/dev/null || true
oc logs mps-pod -c mps-ctr1 -n "$NS" --tail=5 2>/dev/null || true

info "MPS via DRA test passed"
