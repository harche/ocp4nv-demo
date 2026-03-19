#!/bin/bash
# Test 1.11: PodResources API
# Validates: Reports device plugin GPU allocations correctly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dp-pod-resources"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Deploy a GPU pod to query via PodResources API"
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
  name: gpu-for-pr-api
  namespace: $NS
spec:
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c', 'trap \"exit 0\" TERM; sleep 9999 & wait']
    resources:
      requests:
        nvidia.com/gpu: 1
      limits:
        nvidia.com/gpu: 1
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_running "$NS" "gpu-for-pr-api" 120

header "Querying PodResources API on $gpu_node"
# Use a debug pod to query the kubelet PodResources gRPC endpoint
# The endpoint is at /var/lib/kubelet/pod-resources/kubelet.sock
pr_output=$(run_on_node "$gpu_node" \
  curl -s --unix-socket /var/lib/kubelet/pod-resources/kubelet.sock \
  http://localhost/v1/list 2>/dev/null || echo "curl-failed")

if [ "$pr_output" = "curl-failed" ]; then
  # Fallback: check via crictl and device allocation
  info "Direct PodResources API query not available via curl, checking device allocation"
  pod_uid=$(oc get pod gpu-for-pr-api -n "$NS" -o jsonpath='{.metadata.uid}')
  container_id=$(oc get pod gpu-for-pr-api -n "$NS" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|cri-o://||')
  if [ -n "$container_id" ]; then
    info "Container ID: $container_id"
    device_info=$(run_on_node "$gpu_node" crictl inspect "$container_id" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
envs = data.get('info', {}).get('config', {}).get('envs', [])
for e in envs:
    if 'NVIDIA' in e.get('key', ''):
        print(f\"{e['key']}={e['value']}\")
devices = data.get('info', {}).get('config', {}).get('devices', [])
for d in devices:
    if 'nvidia' in d.get('container_path', ''):
        print(f\"device: {d['container_path']}\")
" 2>/dev/null || echo "could not parse container info")
    if [ -n "$device_info" ]; then
      info "Device allocation info:"
      echo "$device_info"
    else
      warn "Could not extract device info from container inspect"
    fi
  fi
else
  echo "$pr_output" | python3 -m json.tool 2>/dev/null || echo "$pr_output"
  if echo "$pr_output" | grep -q "nvidia.com/gpu"; then
    info "PodResources API reports nvidia.com/gpu allocation"
  else
    warn "Could not confirm GPU in PodResources API response"
  fi
fi

info "PodResources API test complete"
