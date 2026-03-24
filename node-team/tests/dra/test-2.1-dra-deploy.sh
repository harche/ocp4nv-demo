#!/bin/bash
# Test 2.1: Deploy NVIDIA DRA driver
# Validates: DRA driver pods running, ResourceSlices published with GPU attributes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

DRA_NS="nvidia-dra-driver-gpu"

header "Checking DRA driver pods"
oc get pods -n "$DRA_NS" -o wide
not_running=$(oc get pods -n "$DRA_NS" --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | wc -l)
if [ "$not_running" -gt 0 ]; then
  error "Some DRA driver pods are not running"
  oc get pods -n "$DRA_NS" --field-selector=status.phase!=Running,status.phase!=Succeeded
  exit 1
fi
info "All DRA driver pods healthy"

header "Checking ResourceSlices"
slices=$(oc get resourceslices --no-headers 2>/dev/null | wc -l)
if [ "$slices" -eq 0 ]; then
  error "No ResourceSlices found"
  exit 1
fi
info "Found $slices ResourceSlice(s)"

header "Verifying GPU attributes in ResourceSlices"
GPU_EXPECTED_ARCH="${GPU_EXPECTED_ARCH:-}"
GPU_EXPECTED_CUDA_CAP="${GPU_EXPECTED_CUDA_CAP:-}"

attrs=$(oc get resourceslices -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
  name = item['metadata']['name']
  devices = item.get('spec', {}).get('devices', [])
  for d in devices:
    attrs = d.get('attributes', {})
    product = attrs.get('productName', {}).get('string', 'unknown')
    arch = attrs.get('architecture', {}).get('string', 'unknown')
    cuda_cap = attrs.get('cudaComputeCapability', {}).get('version', 'unknown')
    mem = d.get('capacity', {}).get('memory', {}).get('value', 'unknown')
    print(f'{name}: product={product} arch={arch} cudaCap={cuda_cap} memory={mem}')
" 2>/dev/null || echo "could not parse")
echo "$attrs"

if [ -n "$attrs" ] && [ "$attrs" != "could not parse" ]; then
  info "GPU attributes found in ResourceSlices"
else
  warn "Could not parse GPU attributes — check ResourceSlice format"
fi

if [ -n "$GPU_EXPECTED_ARCH" ]; then
  if echo "$attrs" | grep -qi "arch=$GPU_EXPECTED_ARCH"; then
    info "Architecture matches expected: $GPU_EXPECTED_ARCH"
  else
    warn "Architecture does not match expected '$GPU_EXPECTED_ARCH' — verify hardware"
  fi
fi

if [ -n "$GPU_EXPECTED_CUDA_CAP" ]; then
  if echo "$attrs" | grep -q "cudaCap=$GPU_EXPECTED_CUDA_CAP"; then
    info "CUDA compute capability matches expected: $GPU_EXPECTED_CUDA_CAP"
  else
    warn "CUDA compute capability does not match expected '$GPU_EXPECTED_CUDA_CAP' — verify driver"
  fi
fi
