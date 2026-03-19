#!/bin/bash
# Test 1.1: Verify GPU Operator is installed and healthy
# Validates: operator pods running, nvidia.com/gpu resource advertised on worker nodes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

header "Checking GPU operator pods"
oc get pods -n nvidia-gpu-operator -o wide
not_running=$(oc get pods -n nvidia-gpu-operator --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | wc -l)
if [ "$not_running" -gt 0 ]; then
  error "Some GPU operator pods are not running:"
  oc get pods -n nvidia-gpu-operator --field-selector=status.phase!=Running,status.phase!=Succeeded
  exit 1
fi
info "All GPU operator pods healthy"

header "Checking nvidia.com/gpu resource on nodes"
gpu_nodes=$(get_gpu_nodes)
if [ -z "$gpu_nodes" ]; then
  error "No GPU nodes found (label: feature.node.kubernetes.io/pci-10de.present)"
  exit 1
fi

for node in $gpu_nodes; do
  count=$(get_gpu_count "$node")
  if [ "$count" -eq 0 ] || [ "$count" = "" ]; then
    error "Node $node has no nvidia.com/gpu allocatable"
    exit 1
  fi
  info "Node $node: nvidia.com/gpu=$count"
done

info "GPU operator validation passed"
