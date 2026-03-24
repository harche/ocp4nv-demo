#!/bin/bash
# Uninstall NVIDIA DRA driver and switch back to device-plugin mode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_TEAM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$NODE_TEAM_ROOT/tests/lib/common.sh"

DRA_NAMESPACE="nvidia-dra-driver-gpu"

header "Step 1: Uninstall DRA driver"
if helm status nvidia-dra-driver-gpu -n "$DRA_NAMESPACE" &>/dev/null; then
  helm uninstall nvidia-dra-driver-gpu -n "$DRA_NAMESPACE"
  info "Helm release removed"
else
  warn "DRA driver helm release not found, skipping"
fi

header "Step 2: Delete DRA namespace"
oc delete namespace "$DRA_NAMESPACE" --ignore-not-found
info "Waiting for namespace cleanup..."
sleep 15

header "Step 3: Restore device-plugin ClusterPolicy"
if [ "${DRIVER_PREINSTALLED:-false}" = "true" ]; then
  info "Using RHCOS4NV ClusterPolicy (driver pre-installed)"
  oc apply -f "$NODE_TEAM_ROOT/gpu-cluster-policy-standard-rhcos4nv.yaml"
else
  oc apply -f "$NODE_TEAM_ROOT/gpu-cluster-policy-standard.yaml"
fi

header "Step 4: Wait for GPU operator to reconcile"
sleep 30
wait_for_nodes_ready 600

info "Switched back to device-plugin mode"
