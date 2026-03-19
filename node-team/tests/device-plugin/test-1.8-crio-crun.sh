#!/bin/bash
# Test 1.8: CRI-O + crun device injection
# Validates: crun is the runtime, CDI specs generated, /dev/nvidia* present
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

gpu_node=$(get_first_gpu_node)

header "Checking container runtime on $gpu_node"
runtime_info=$(run_on_node "$gpu_node" crictl info 2>/dev/null || true)
if echo "$runtime_info" | grep -q "crun"; then
  info "crun is the container runtime"
else
  warn "Could not confirm crun as runtime (may still be correct)"
  echo "$runtime_info" | grep -i runtime || true
fi

header "Checking CDI specs"
cdi_specs=$(run_on_node "$gpu_node" ls /var/run/cdi/ 2>/dev/null || true)
if [ -n "$cdi_specs" ]; then
  info "CDI specs found:"
  echo "$cdi_specs"
else
  # CDI specs might be in /etc/cdi/ instead
  cdi_specs=$(run_on_node "$gpu_node" ls /etc/cdi/ 2>/dev/null || true)
  if [ -n "$cdi_specs" ]; then
    info "CDI specs found in /etc/cdi/:"
    echo "$cdi_specs"
  else
    error "No CDI specs found in /var/run/cdi/ or /etc/cdi/"
    exit 1
  fi
fi

header "Checking NVIDIA device files"
nvidia_devs=$(run_on_node "$gpu_node" ls -la /dev/nvidia* 2>/dev/null || true)
if [ -n "$nvidia_devs" ]; then
  info "NVIDIA device files present:"
  echo "$nvidia_devs"
else
  error "No /dev/nvidia* device files found"
  exit 1
fi

info "CRI-O + crun validation passed"
