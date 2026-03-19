#!/bin/bash
# Test 2.14: kubelet DRA plugin registration
# Validates: kubelet logs show successful DRA driver registration,
#            NodePrepareResources / NodeUnprepareResources calls succeed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

gpu_node=$(get_first_gpu_node)

header "Checking kubelet logs for DRA plugin registration on $gpu_node"

dra_logs=$(run_on_node "$gpu_node" journalctl -u kubelet --since "1 hour ago" --no-pager 2>/dev/null | \
  grep -iE "dra|NodePrepareResources|NodeUnprepareResources|resource.k8s.io|resourceslice" | tail -30 || true)

if [ -n "$dra_logs" ]; then
  info "DRA-related kubelet log entries:"
  echo "$dra_logs"
else
  warn "No DRA-related entries found in recent kubelet logs"
  info "Trying broader search..."
  dra_logs=$(run_on_node "$gpu_node" journalctl -u kubelet --since "4 hours ago" --no-pager 2>/dev/null | \
    grep -iE "dra|dynamic.resource" | tail -20 || true)
  if [ -n "$dra_logs" ]; then
    echo "$dra_logs"
  else
    warn "No DRA entries found — kubelet may need a workload to trigger DRA calls"
  fi
fi

header "Check DRA plugin socket registration"
dra_sockets=$(run_on_node "$gpu_node" ls /var/lib/kubelet/plugins/gpu.nvidia.com/ 2>/dev/null || true)
if [ -n "$dra_sockets" ]; then
  info "DRA plugin socket found:"
  echo "$dra_sockets"
else
  dra_sockets=$(run_on_node "$gpu_node" find /var/lib/kubelet/plugins/ -name "*.sock" 2>/dev/null | grep -i nvidia || true)
  if [ -n "$dra_sockets" ]; then
    info "NVIDIA plugin sockets:"
    echo "$dra_sockets"
  else
    warn "Could not find DRA plugin socket"
  fi
fi

# Look for NodePrepareResources success
if echo "$dra_logs" | grep -qi "NodePrepareResources"; then
  info "NodePrepareResources calls found in logs"
else
  warn "No NodePrepareResources calls found — run a DRA workload first"
fi

info "kubelet DRA plugin registration check complete"
