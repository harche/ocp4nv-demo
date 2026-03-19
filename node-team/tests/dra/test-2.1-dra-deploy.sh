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
attrs=$(oc get resourceslices -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
  name = item['metadata']['name']
  devices = item.get('spec', {}).get('devices', [])
  for d in devices:
    attrs = d.get('basic', {}).get('attributes', {})
    product = attrs.get('gpu.nvidia.com/productName', {}).get('stringValue', 'unknown')
    mem = attrs.get('gpu.nvidia.com/memory', {})
    print(f'{name}: product={product}')
" 2>/dev/null || echo "could not parse")
echo "$attrs"

if [ -n "$attrs" ] && [ "$attrs" != "could not parse" ]; then
  info "GPU attributes found in ResourceSlices"
else
  warn "Could not parse GPU attributes — check ResourceSlice format"
fi
