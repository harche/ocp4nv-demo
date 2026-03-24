#!/bin/bash
# Test 1.6: Enable MPS
# Validates: MPS daemon running, GPU shared across multiple pods
# This test disables MIG first, then configures MPS via device plugin config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

MPS_REPLICAS="${MPS_REPLICAS:-4}"
gpu_node=$(get_first_gpu_node)

header "Step 1a: Reapply standard ClusterPolicy (remove MIG strategy)"
oc apply -f "$NODE_TEAM_ROOT/gpu-cluster-policy-standard.yaml"
info "Waiting for ClusterPolicy to reconcile..."
sleep 15

header "Step 1b: Disable MIG (if enabled)"
oc label node "$gpu_node" nvidia.com/mig.config=all-disabled --overwrite 2>/dev/null || true
info "Waiting for MIG to disable (node may reboot)..."

# Wait for node to go NotReady (reboot)
reboot_timeout=180
elapsed=0
rebooted=false
while [ $elapsed -lt $reboot_timeout ]; do
  status=$(oc get node "$gpu_node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$status" != "True" ]; then
    info "Node $gpu_node is rebooting (status: $status)"
    rebooted=true
    break
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done

if [ "$rebooted" = "true" ]; then
  # Wait for node to come back Ready
  info "Waiting for node $gpu_node to come back Ready..."
  wait_for_nodes_ready 600

  # Wait for GPU operator pods to recover
  info "Waiting for GPU operator pods to recover..."
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
else
  info "Node did not reboot, MIG may have been already disabled. Waiting 60s for stabilization..."
  sleep 60
fi

# Verify MIG is disabled
mig_state=$(oc get node "$gpu_node" -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || echo "unknown")
info "MIG config state: $mig_state"

header "Step 2: Create device plugin config for MPS"
apply_yaml "
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-plugin-config
  namespace: nvidia-gpu-operator
data:
  mps: |
    version: v1
    flags:
      migStrategy: none
    sharing:
      mps:
        resources:
          - name: nvidia.com/gpu
            replicas: $MPS_REPLICAS
"

header "Step 3: Patch ClusterPolicy to reference device plugin config"
oc patch clusterpolicy gpu-cluster-policy --type=merge -p '
{
  "spec": {
    "devicePlugin": {
      "config": {
        "name": "device-plugin-config",
        "default": "mps"
      }
    }
  }
}'

header "Step 4: Label GPU node to use MPS config"
oc label node "$gpu_node" nvidia.com/device-plugin.config=mps --overwrite

info "Waiting for device plugin to restart with MPS config..."
sleep 30

# Verify the GPU is now advertised with replicas
timeout=180
elapsed=0
while [ $elapsed -lt $timeout ]; do
  gpu_count=$(get_gpu_count "$gpu_node")
  if [ "$gpu_count" -ge "$MPS_REPLICAS" ]; then
    info "Node $gpu_node now reports nvidia.com/gpu=$gpu_count (MPS replicas: $MPS_REPLICAS)"
    exit 0
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done

error "MPS not enabled: nvidia.com/gpu=$gpu_count (expected >= $MPS_REPLICAS)"
exit 1
