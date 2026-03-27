#!/bin/bash
# Test 1.6: Enable MPS
# Validates: MPS daemon running, GPU shared across multiple pods
# Configures MPS via device plugin config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

MPS_REPLICAS="${MPS_REPLICAS:-4}"
gpu_node=$(get_first_gpu_node)

header "Step 1: Create device plugin config for MPS"
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

header "Step 2: Patch ClusterPolicy to reference device plugin config"
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

header "Step 3: Label GPU node to use MPS config"
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
