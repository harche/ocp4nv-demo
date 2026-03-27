#!/bin/bash
# Test 2.2: DeviceClass discovery
# Validates: gpu.nvidia.com DeviceClass exists
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

header "Checking DeviceClasses"
oc get deviceclasses

if oc get deviceclass gpu.nvidia.com &>/dev/null; then
  info "DeviceClass gpu.nvidia.com exists"
  exit 0
else
  error "DeviceClass gpu.nvidia.com not found"
  exit 1
fi
