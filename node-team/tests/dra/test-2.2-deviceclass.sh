#!/bin/bash
# Test 2.2: DeviceClass discovery
# Validates: gpu.nvidia.com and mig.nvidia.com DeviceClasses exist
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

header "Checking DeviceClasses"
oc get deviceclasses

found_gpu=false
found_mig=false

if oc get deviceclass gpu.nvidia.com &>/dev/null; then
  info "DeviceClass gpu.nvidia.com exists"
  found_gpu=true
else
  error "DeviceClass gpu.nvidia.com not found"
fi

if oc get deviceclass mig.nvidia.com &>/dev/null; then
  info "DeviceClass mig.nvidia.com exists"
  found_mig=true
else
  warn "DeviceClass mig.nvidia.com not found (may appear after MIG is enabled)"
fi

if $found_gpu; then
  exit 0
else
  exit 1
fi
