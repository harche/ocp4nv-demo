#!/bin/bash
# Test 1.4: Enable MIG on GPU(s)
# Validates: MIG profiles created, nvidia.com/mig-* resources advertised
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

MIG_PROFILE="${MIG_PROFILE:-all-1g.5gb}"

gpu_node=$(get_first_gpu_node)
info "Enabling MIG on node $gpu_node with profile: $MIG_PROFILE"

oc label node "$gpu_node" nvidia.com/mig.config="$MIG_PROFILE" --overwrite

header "Waiting for MIG manager to reconfigure"
# MIG reconfiguration can take a few minutes (node may reboot)
sleep 30
timeout=300
elapsed=0
while [ $elapsed -lt $timeout ]; do
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

error "No MIG resources found on $gpu_node after ${timeout}s"
oc get node "$gpu_node" -o jsonpath='{.status.allocatable}' | python3 -m json.tool
exit 1
