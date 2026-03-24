#!/bin/bash
# Test 2.8: Prioritized alternatives — preferred device selected (OCPSTRAT-2115)
# Validates: firstAvailable picks preferred MIG profile
# Depends on: MIG must be enabled
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NS="test-dra-preferred"
MIG_PROFILE_SMALL="${MIG_PROFILE_SMALL:-1g.5gb}"
MIG_PROFILE_MEDIUM="${MIG_PROFILE_MEDIUM:-3g.20gb}"
MIG_PROFILE="${MIG_PROFILE:-all-1g.5gb}"

check_cdmm_mig_compatible

cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT

gpu_node=$(get_first_gpu_node)

header "Ensure MIG is enabled"
mig_state=$(oc get node "$gpu_node" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['labels'].get('nvidia.com/mig.config','none'))" 2>/dev/null || echo "none")

if [ "$mig_state" != "$MIG_PROFILE" ]; then
  info "MIG is '$mig_state' — enabling $MIG_PROFILE..."
  oc label node "$gpu_node" nvidia.com/mig.config="$MIG_PROFILE" --overwrite

  # Wait for reboot
  reboot_timeout=180
  elapsed=0
  while [ $elapsed -lt $reboot_timeout ]; do
    node_status=$(oc get node "$gpu_node" -o json 2>/dev/null | python3 -c "import sys,json; cs=[c for c in json.load(sys.stdin)['status']['conditions'] if c['type']=='Ready']; print(cs[0]['status'] if cs else 'Unknown')" 2>/dev/null || echo "Unknown")
    if [ "$node_status" != "True" ]; then
      info "Node is rebooting"
      break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done

  wait_for_nodes_ready 600
  sleep 30

  # Wait for GPU operator pods
  op_timeout=600
  elapsed=0
  while [ $elapsed -lt $op_timeout ]; do
    not_ready=$(oc get pods -n nvidia-gpu-operator --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | wc -l | tr -d ' ')
    total=$(oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ -z "$not_ready" ] && not_ready=99
    [ -z "$total" ] && total=0
    if [ "$not_ready" -eq 0 ] && [ "$total" -gt 5 ]; then
      info "All GPU operator pods healthy ($total pods)"
      break
    fi
    sleep 20
    elapsed=$((elapsed + 20))
  done

  # Restart DRA pods to re-enumerate MIG devices
  info "Restarting DRA driver pods..."
  oc delete pods -n nvidia-dra-driver-gpu --all 2>/dev/null || true
  sleep 15
  dra_timeout=300
  elapsed=0
  while [ $elapsed -lt $dra_timeout ]; do
    dra_ready=$(oc get pods -n nvidia-dra-driver-gpu -o json 2>/dev/null | python3 -c "
import sys,json
pods = json.load(sys.stdin)['items']
ready = len([p for p in pods if p['status']['phase'] == 'Running'])
print(ready)" 2>/dev/null || echo "0")
    if [ "$dra_ready" -gt 0 ]; then
      info "DRA driver pods ready ($dra_ready)"
      break
    fi
    sleep 15
    elapsed=$((elapsed + 15))
  done
else
  info "MIG already enabled ($mig_state) — skipping"
fi

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
  name: preferred-mig
spec:
  spec:
    devices:
      requests:
      - name: mig
        firstAvailable:
        - name: medium
          deviceClassName: mig.nvidia.com
          selectors:
          - cel:
              expression: \"device.attributes['gpu.nvidia.com'].profile == '$MIG_PROFILE_MEDIUM'\"
        - name: small
          deviceClassName: mig.nvidia.com
          selectors:
          - cel:
              expression: \"device.attributes['gpu.nvidia.com'].profile == '$MIG_PROFILE_SMALL'\"
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $NS
  name: preferred-pod
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: ubuntu:22.04
    command: ['bash', '-c', 'nvidia-smi --query-gpu=uuid,name --format=csv,noheader,nounits; echo PREFERRED_TEST_DONE']
    resources:
      claims:
      - name: mig
  resourceClaims:
  - name: mig
    resourceClaimTemplateName: preferred-mig
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
"

wait_for_pod_complete "$NS" "preferred-pod" 120

logs=$(oc logs preferred-pod -n "$NS")
echo "$logs"

if echo "$logs" | grep -q "PREFERRED_TEST_DONE"; then
  info "Prioritized alternatives (firstAvailable) test passed"
  info "Pod was allocated a MIG profile via firstAvailable preference"
else
  error "Preferred device test did not complete"
  exit 1
fi
