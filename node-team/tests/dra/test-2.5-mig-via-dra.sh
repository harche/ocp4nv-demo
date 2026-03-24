#!/bin/bash
# Test 2.5: MIG via DRA
# Validates: MIG slices visible as ResourceSlices, pod allocated specific MIG profile via CEL
# Depends on: MIG must be enabled on the GPU (nvidia.com/mig.config label)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-mig"
MIG_PROFILE="${MIG_PROFILE:-all-1g.5gb}"
MIG_PROFILE_SMALL="${MIG_PROFILE_SMALL:-1g.5gb}"

check_cdmm_mig_compatible

cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Step 1: Enable MIG (profile: $MIG_PROFILE)"
oc label node "$gpu_node" nvidia.com/mig.config="$MIG_PROFILE" --overwrite
info "Waiting for MIG reconfiguration (node may reboot)..."

# Wait for node to go NotReady (reboot)
reboot_timeout=180
elapsed=0
while [ $elapsed -lt $reboot_timeout ]; do
  node_status=$(oc get node "$gpu_node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$node_status" != "True" ]; then
    info "Node $gpu_node is rebooting"
    break
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done

# Wait for node to come back Ready
wait_for_nodes_ready 600
sleep 30  # let API server stabilize after reboot

# Wait for GPU operator pods to recover
info "Waiting for GPU operator pods to recover..."
op_timeout=600
elapsed=0
while [ $elapsed -lt $op_timeout ]; do
  not_ready=$(oc get pods -n nvidia-gpu-operator --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | wc -l | tr -d ' ' || echo "99")
  total=$(oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  if [ "$not_ready" -eq 0 ] && [ "$total" -gt 5 ]; then
    info "All GPU operator pods healthy ($total pods)"
    break
  fi
  info "GPU operator pods: $((total - not_ready))/$total ready"
  sleep 20
  elapsed=$((elapsed + 20))
done

# Restart DRA driver pods to re-enumerate MIG devices
info "Restarting DRA driver pods to detect MIG devices..."
oc delete pods -n nvidia-dra-driver-gpu --all 2>/dev/null || true
sleep 15
dra_timeout=300
elapsed=0
while [ $elapsed -lt $dra_timeout ]; do
  dra_not_ready=$(oc get pods -n nvidia-dra-driver-gpu --no-headers --field-selector=status.phase!=Running 2>/dev/null | wc -l | tr -d ' ' || echo "99")
  dra_total=$(oc get pods -n nvidia-dra-driver-gpu --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  if [ "$dra_not_ready" -eq 0 ] && [ "$dra_total" -gt 0 ]; then
    info "All DRA driver pods healthy ($dra_total pods)"
    break
  fi
  sleep 15
  elapsed=$((elapsed + 15))
done

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
    attrs = d.get('attributes', {})
    profile = attrs.get('profile', {}).get('string', '')
    if profile:
      count += 1
      print(f'  MIG device: profile={profile}')
print(f'total={count}')
" 2>/dev/null || echo "total=0")
  echo "$mig_slices"
  if echo "$mig_slices" | grep -q "$MIG_PROFILE_SMALL"; then
    mig_found=true
    break
  fi
  sleep 15
  elapsed=$((elapsed + 15))
done

if ! $mig_found; then
  error "No MIG ResourceSlices found with profile $MIG_PROFILE_SMALL"
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
      - name: mig-slice
        exactly:
          deviceClassName: mig.nvidia.com
          selectors:
          - cel:
              expression: \"device.attributes['gpu.nvidia.com'].profile == '$MIG_PROFILE_SMALL'\"
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
    command: ['bash', '-c', 'nvidia-smi --query-gpu=uuid,name --format=csv,noheader,nounits; echo MIG_TEST_DONE']
    resources:
      claims:
      - name: mig
        request: mig-slice
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
