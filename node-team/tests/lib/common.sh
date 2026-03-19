#!/bin/bash
# Shared functions for GPU validation tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NODE_TEAM_ROOT="$REPO_ROOT"
OCP4NV_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; }
header() { echo -e "\n${BLUE}=== $* ===${NC}"; }

get_gpu_nodes() {
  oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true \
    -o jsonpath='{.items[*].metadata.name}'
}

get_first_gpu_node() {
  oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true \
    -o jsonpath='{.items[0].metadata.name}'
}

get_gpu_count() {
  local node=$1
  oc get node "$node" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0"
}

wait_for_pods_ready() {
  local ns=$1
  local timeout=${2:-300}
  info "Waiting for pods in $ns to be ready (timeout: ${timeout}s)..."
  oc wait --for=condition=Ready pods --all -n "$ns" --timeout="${timeout}s"
}

wait_for_pod_complete() {
  local ns=$1
  local pod=$2
  local timeout=${3:-120}
  info "Waiting for pod $pod to complete (timeout: ${timeout}s)..."
  oc wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" -n "$ns" --timeout="${timeout}s"
}

wait_for_pod_running() {
  local ns=$1
  local pod=$2
  local timeout=${3:-120}
  info "Waiting for pod $pod to be running (timeout: ${timeout}s)..."
  oc wait --for=condition=Ready "pod/$pod" -n "$ns" --timeout="${timeout}s"
}

wait_for_csv() {
  local ns=$1
  local timeout=${2:-300}
  local elapsed=0
  info "Waiting for CSV in $ns to succeed..."
  while [ $elapsed -lt "$timeout" ]; do
    if oc get csv -n "$ns" -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Succeeded; then
      info "CSV succeeded"
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  error "Timed out waiting for CSV in $ns"
  return 1
}

wait_for_nodes_ready() {
  local timeout=${1:-600}
  local elapsed=0
  info "Waiting for all nodes to be Ready (timeout: ${timeout}s)..."
  while [ $elapsed -lt "$timeout" ]; do
    local not_ready
    not_ready=$(oc get nodes --no-headers | grep -cv " Ready" || true)
    if [ "$not_ready" -eq 0 ]; then
      info "All nodes Ready"
      return 0
    fi
    sleep 15
    elapsed=$((elapsed + 15))
  done
  error "Timed out waiting for nodes"
  return 1
}

wait_for_mcp() {
  local timeout=${1:-900}
  local elapsed=0
  info "Waiting for MachineConfigPool to finish updating (timeout: ${timeout}s)..."
  while [ $elapsed -lt "$timeout" ]; do
    local updating
    updating=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "Unknown")
    local degraded
    degraded=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")
    if [ "$updating" = "False" ] && [ "$degraded" = "False" ]; then
      info "MachineConfigPool stable"
      return 0
    fi
    sleep 30
    elapsed=$((elapsed + 30))
  done
  error "Timed out waiting for MCP"
  return 1
}

cleanup_ns() {
  local ns=$1
  info "Cleaning up namespace $ns..."
  oc delete namespace "$ns" --ignore-not-found --wait=false 2>/dev/null || true
}

# Wait for namespace to be fully deleted
wait_for_ns_deleted() {
  local ns=$1
  local timeout=${2:-120}
  local elapsed=0
  while [ $elapsed -lt "$timeout" ]; do
    if ! oc get namespace "$ns" &>/dev/null; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  error "Timed out waiting for namespace $ns to be deleted"
  return 1
}

run_on_node() {
  local node=$1
  shift
  oc debug "node/$node" --quiet -- chroot /host "$@" 2>/dev/null
}

# Apply inline YAML from a heredoc
apply_yaml() {
  echo "$1" | oc apply -f -
}
