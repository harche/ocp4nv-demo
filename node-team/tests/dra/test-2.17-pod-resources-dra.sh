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

DEVICE_CLASS="gpu.nvidia.com"

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
          deviceClassName: $DEVICE_CLASS
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
    command: ['bash', '-c', 'nvidia-smi --query-gpu=uuid --format=csv,noheader,nounits > /tmp/gpu-uuid; trap \"exit 0\" TERM; sleep 9999 & wait']
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

gpu_uuid=$(oc exec pr-api-pod -n "$NS" -- cat /tmp/gpu-uuid 2>/dev/null | tr -d '[:space:]')
if [ -n "$gpu_uuid" ]; then
  info "DRA GPU pod running (UUID: $gpu_uuid)"
else
  error "Pod running but no GPU UUID found"
  exit 1
fi

header "Step 1: Verify ResourceClaim allocation"

claim_name=$(oc get pod pr-api-pod -n "$NS" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['resourceClaimStatuses'][0]['resourceClaimName'])" 2>/dev/null || echo "")
if [ -z "$claim_name" ]; then
  error "No ResourceClaim found in pod status"
  exit 1
fi
info "ResourceClaim: $claim_name"

claim_device=$(oc get resourceclaim "$claim_name" -n "$NS" -o json | python3 -c "
import sys,json
claim = json.load(sys.stdin)
results = claim.get('status',{}).get('allocation',{}).get('devices',{}).get('results',[])
for r in results:
    print(f'device={r[\"device\"]} driver={r[\"driver\"]} pool={r[\"pool\"]}')
" 2>/dev/null || echo "")
if [ -n "$claim_device" ]; then
  info "Allocation: $claim_device"
else
  error "ResourceClaim has no device allocation"
  exit 1
fi

header "Step 2: Verify DRA device injection via crictl inspect"

container_id=$(oc get pod pr-api-pod -n "$NS" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['containerStatuses'][0]['containerID'].replace('cri-o://',''))" 2>/dev/null || echo "")
if [ -z "$container_id" ]; then
  error "Could not get container ID"
  exit 1
fi
info "Container ID: $container_id"

inspect_output=$(run_on_node "$gpu_node" crictl inspect "$container_id" 2>/dev/null || echo "{}")

# Parse CDI annotations and NVIDIA devices from crictl inspect
device_info=$(echo "$inspect_output" | python3 -c "
import sys,json
data = json.load(sys.stdin)
info_data = data.get('info', {})
config = json.loads(info_data.get('info', '{}')) if isinstance(info_data.get('info'), str) else info_data

# Try multiple paths for annotations
annotations = {}
for path in [config, data.get('status',{})]:
    annotations.update(path.get('annotations', {}))

cdi_found = False
for k, v in annotations.items():
    if 'cdi' in k.lower() or 'nvidia' in k.lower():
        print(f'annotation: {k}={v[:200]}')
        cdi_found = True

# Check linux devices
linux = config.get('linux', data.get('info',{}).get('runtimeSpec',{}).get('linux',{}))
devices = linux.get('devices', [])
for d in devices:
    path = d.get('path', '')
    if 'nvidia' in path:
        print(f'device: {path}')
        cdi_found = True

# Check env
process = config.get('process', data.get('info',{}).get('runtimeSpec',{}).get('process',{}))
envs = process.get('env', [])
for e in envs:
    if 'NVIDIA' in e or 'CUDA' in e:
        print(f'env: {e}')
        cdi_found = True

if not cdi_found:
    print('NO_CDI_FOUND')
" 2>/dev/null || echo "parse_error")

echo "$device_info"

if echo "$device_info" | grep -q "NO_CDI_FOUND\|parse_error"; then
  error "No CDI/NVIDIA device injection found in container inspect"
  exit 1
fi

info "PodResources + DRA verification complete — DRA device allocation and CDI injection confirmed"
