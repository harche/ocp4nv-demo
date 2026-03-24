#!/bin/bash
# Test 1.4: Enable MIG on GPU(s)
# Validates: MIG profiles created, nvidia.com/mig-* resources advertised
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

MIG_PROFILE="${MIG_PROFILE:-all-1g.5gb}"

check_cdmm_mig_compatible

gpu_node=$(get_first_gpu_node)
info "Enabling MIG on node $gpu_node with profile: $MIG_PROFILE"

oc label node "$gpu_node" nvidia.com/mig.config="$MIG_PROFILE" --overwrite

header "Waiting for MIG manager to reconfigure (node will reboot)"

# Wait for node to go NotReady (reboot triggered by MIG reconfiguration)
info "Waiting for node $gpu_node to begin rebooting..."
reboot_timeout=180
elapsed=0
while [ $elapsed -lt $reboot_timeout ]; do
  status=$(oc get node "$gpu_node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$status" != "True" ]; then
    info "Node $gpu_node is rebooting (status: $status)"
    break
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done

# Wait for node to come back Ready
info "Waiting for node $gpu_node to come back Ready..."
wait_for_nodes_ready 600

# Wait for GPU operator pods to recover
header "Waiting for GPU operator pods to recover"
op_timeout=600
elapsed=0
while [ $elapsed -lt $op_timeout ]; do
  not_ready=$(oc get pods -n nvidia-gpu-operator --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | wc -l | tr -d ' ')
  total=$(oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$not_ready" -eq 0 ] && [ "$total" -gt 5 ]; then
    info "All GPU operator pods healthy ($total pods)"
    break
  fi
  info "GPU operator pods: $((total - not_ready))/$total ready"
  sleep 20
  elapsed=$((elapsed + 20))
done

# Check for MIG resources
header "Checking for MIG resources"
mig_timeout=300
elapsed=0
while [ $elapsed -lt $mig_timeout ]; do
  mig_resources=$(oc get node "$gpu_node" -o json | python3 -c "
import sys, json
node = json.load(sys.stdin)
alloc = node.get('status', {}).get('allocatable', {})
mig = {k: v for k, v in alloc.items() if 'mig' in k}
for k, v in mig.items():
    print(f'{k}={v}')
" 2>/dev/null || true)

  if [ -n "$mig_resources" ]; then
    info "MIG resources found on $gpu_node:"
    echo "$mig_resources"
    exit 0
  fi
  sleep 15
  elapsed=$((elapsed + 15))
done

error "No MIG resources found on $gpu_node after waiting for reboot + ${mig_timeout}s"
oc get node "$gpu_node" -o jsonpath='{.status.allocatable}' | python3 -m json.tool
exit 1
