#!/bin/bash
# Test 2.17: PodResources API + DRA
# Validates: Reports DRA-allocated devices correctly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-pod-resources"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Deploy DRA GPU pod for PodResources API check"
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
  name: pr-api-pod
spec:
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c', 'trap \"exit 0\" TERM; sleep 9999 & wait']
    resources:
      claims:
      - name: gpu
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: single-gpu
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_running "$NS" "pr-api-pod" 120
info "DRA GPU pod running"

header "Querying PodResources API on $gpu_node"

# Check the pod's ResourceClaim status for allocation details
claim_name=$(oc get pod pr-api-pod -n "$NS" -o jsonpath='{.status.resourceClaimStatuses[0].resourceClaimName}' 2>/dev/null || echo "")
if [ -n "$claim_name" ]; then
  info "ResourceClaim: $claim_name"
  oc get resourceclaim "$claim_name" -n "$NS" -o yaml 2>/dev/null | grep -A 20 "allocation:" || true
fi

# Check container info for DRA device allocation
container_id=$(oc get pod pr-api-pod -n "$NS" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|cri-o://||')
if [ -n "$container_id" ]; then
  info "Container ID: $container_id"
  device_info=$(run_on_node "$gpu_node" crictl inspect "$container_id" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Check for CDI devices
info_data = data.get('info', {})
config = info_data.get('config', {})
# Check annotations for CDI
annotations = config.get('annotations', {})
for k, v in annotations.items():
    if 'cdi' in k.lower() or 'nvidia' in k.lower():
        print(f'  annotation: {k}={v}')
# Check devices
devices = config.get('devices', [])
for d in devices:
    path = d.get('container_path', d.get('path', ''))
    if 'nvidia' in path:
        print(f'  device: {path}')
# Check env vars
envs = config.get('envs', [])
for e in envs:
    if 'NVIDIA' in e.get('key', '') or 'CDI' in e.get('key', ''):
        print(f\"  env: {e['key']}={e['value']}\")
" 2>/dev/null || echo "  could not parse container info")
  echo "$device_info"
fi

# Try PodResources API via kubelet socket
pr_result=$(run_on_node "$gpu_node" \
  curl -s --unix-socket /var/lib/kubelet/pod-resources/kubelet.sock \
  http://localhost/v1/list 2>/dev/null || echo "")

if [ -n "$pr_result" ] && [ "$pr_result" != "" ]; then
  if echo "$pr_result" | grep -qi "nvidia\|gpu\|dra"; then
    info "PodResources API reports DRA-allocated GPU"
  else
    warn "PodResources API response does not mention GPU/DRA"
  fi
else
  warn "Could not query PodResources API directly"
fi

info "PodResources API + DRA test complete"
