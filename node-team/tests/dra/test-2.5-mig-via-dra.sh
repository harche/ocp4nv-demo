#!/bin/bash
# Test 2.5: MIG via DRA
# Validates: MIG slices visible as ResourceSlices, pod allocated specific MIG profile via CEL
# Depends on: MIG must be enabled on the GPU (nvidia.com/mig.config label)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-mig"
MIG_PROFILE="${MIG_PROFILE:-all-1g.5gb}"
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Step 1: Enable MIG (profile: $MIG_PROFILE)"
oc label node "$gpu_node" nvidia.com/mig.config="$MIG_PROFILE" --overwrite
info "Waiting for MIG reconfiguration..."
sleep 60

header "Step 2: Verify MIG ResourceSlices"
timeout=180
elapsed=0
mig_found=false
while [ $elapsed -lt $timeout ]; do
  mig_slices=$(oc get resourceslices -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
count = 0
for item in data.get('items', []):
  for d in item.get('spec', {}).get('devices', []):
    attrs = d.get('basic', {}).get('attributes', {})
    profile = attrs.get('gpu.nvidia.com/profile', {}).get('stringValue', '')
    if profile:
      count += 1
      print(f'  MIG device: profile={profile}')
print(f'total={count}')
" 2>/dev/null || echo "total=0")
  echo "$mig_slices"
  if echo "$mig_slices" | grep -q "1g.5gb"; then
    mig_found=true
    break
  fi
  sleep 15
  elapsed=$((elapsed + 15))
done

if ! $mig_found; then
  error "No MIG ResourceSlices found with profile 1g.5gb"
  exit 1
fi

header "Step 3: Deploy pod requesting MIG via DRA"
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
  name: mig-device
spec:
  spec:
    devices:
      requests:
      - name: mig-1g-5gb
        exactly:
          deviceClassName: mig.nvidia.com
          selectors:
          - cel:
              expression: \"device.attributes['gpu.nvidia.com'].profile == '1g.5gb'\"
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $NS
  name: mig-pod
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c', 'nvidia-smi -L; echo MIG_TEST_DONE']
    resources:
      claims:
      - name: mig
        request: mig-1g-5gb
  resourceClaims:
  - name: mig
    resourceClaimTemplateName: mig-device
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "mig-pod" 120

logs=$(oc logs mig-pod -n "$NS")
echo "$logs"

if echo "$logs" | grep -q "MIG_TEST_DONE"; then
  info "MIG via DRA allocation passed"
else
  error "MIG pod did not complete successfully"
  exit 1
fi
