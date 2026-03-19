#!/bin/bash
# Install NVIDIA DRA driver on OpenShift
# Transitions from device-plugin mode to DRA mode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_TEAM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$NODE_TEAM_ROOT/tests/lib/common.sh"

DRA_CHART_VERSION="${DRA_CHART_VERSION:-25.12.0}"
DRA_NAMESPACE="nvidia-dra-driver-gpu"

header "Step 1: Switch ClusterPolicy to DRA mode (disable device plugin)"
oc apply -f "$NODE_TEAM_ROOT/gpu-cluster-policy-dra.yaml"

header "Step 2: Wait for GPU operator to reconcile"
info "Waiting for device plugin pods to terminate..."
sleep 30
# Wait until no device-plugin pods are running
timeout=300
elapsed=0
while [ $elapsed -lt $timeout ]; do
  dp_pods=$(oc get pods -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset --no-headers 2>/dev/null | wc -l || echo "0")
  if [ "$dp_pods" -eq 0 ]; then
    info "Device plugin pods terminated"
    break
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done

header "Step 3: Wait for nodes to be Ready"
wait_for_nodes_ready 600

header "Step 4: Add NVIDIA helm repo"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update nvidia

header "Step 5: Install DRA driver (version: $DRA_CHART_VERSION)"
if helm status nvidia-dra-driver-gpu -n "$DRA_NAMESPACE" &>/dev/null; then
  info "DRA driver already installed, upgrading..."
  helm upgrade nvidia-dra-driver-gpu nvidia/nvidia-dra-driver-gpu \
    --version="$DRA_CHART_VERSION" \
    --namespace "$DRA_NAMESPACE" \
    --set nvidiaDriverRoot=/run/nvidia/driver
else
  helm install nvidia-dra-driver-gpu nvidia/nvidia-dra-driver-gpu \
    --version="$DRA_CHART_VERSION" \
    --create-namespace \
    --namespace "$DRA_NAMESPACE" \
    --set nvidiaDriverRoot=/run/nvidia/driver
fi

header "Step 6: Verify DRA driver"
info "Waiting for DRA driver pods..."
sleep 15
oc get pods -n "$DRA_NAMESPACE"

info "Checking ResourceSlices..."
timeout=120
elapsed=0
while [ $elapsed -lt $timeout ]; do
  slices=$(oc get resourceslices --no-headers 2>/dev/null | wc -l || echo "0")
  if [ "$slices" -gt 0 ]; then
    info "Found $slices ResourceSlice(s)"
    oc get resourceslices
    break
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done

if [ "$slices" -eq 0 ]; then
  error "No ResourceSlices found after ${timeout}s"
  exit 1
fi

info "Checking DeviceClasses..."
oc get deviceclasses

echo ""
info "DRA driver installation complete"
