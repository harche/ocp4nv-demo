# Test Library Reference

> Parent doc: [../CLAUDE.md](../CLAUDE.md)

## Files

| File | Purpose |
|------|---------|
| `common.sh` | Shared utility functions — sourced by every test script |
| `assert.sh` | Test result tracking — sourced only by `run-all.sh` scripts |

---

## common.sh — Functions

### Path Variables

| Variable | Value |
|----------|-------|
| `SCRIPT_DIR` | Directory containing `common.sh` (`tests/lib/`) |
| `REPO_ROOT` | Resolves to `node-team/` |
| `NODE_TEAM_ROOT` | Same as `REPO_ROOT` |
| `OCP4NV_ROOT` | Parent `ocp4nv-demo/` directory |

### Logging

| Function | Output |
|----------|--------|
| `info "msg"` | `[INFO] msg` (green) |
| `warn "msg"` | `[WARN] msg` (yellow) |
| `error "msg"` | `[ERROR] msg` (red) |
| `header "msg"` | `=== msg ===` (blue, with leading newline) |

### GPU Node Discovery

| Function | Returns |
|----------|---------|
| `get_gpu_nodes` | Space-separated list of node names with NVIDIA GPUs (uses NFD label `pci-10de.present`) |
| `get_first_gpu_node` | First GPU node name |
| `get_gpu_count <node>` | Allocatable `nvidia.com/gpu` count on a node |

### Wait Functions

All return 0 on success, 1 on timeout.

| Function | Args | Default Timeout |
|----------|------|-----------------|
| `wait_for_pods_ready <ns>` | namespace, [timeout] | 300s |
| `wait_for_pod_complete <ns> <pod>` | namespace, pod name, [timeout] | 120s |
| `wait_for_pod_running <ns> <pod>` | namespace, pod name, [timeout] | 120s |
| `wait_for_csv <ns>` | namespace, [timeout] | 300s |
| `wait_for_nodes_ready` | [timeout] | 600s |
| `wait_for_mcp` | [timeout] | 900s |
| `wait_for_ns_deleted <ns>` | namespace, [timeout] | 120s |

### Cluster Operations

| Function | Purpose |
|----------|---------|
| `cleanup_ns <ns>` | Delete namespace (non-blocking, ignores not-found) |
| `run_on_node <node> <cmd...>` | Run command on node via `oc debug` + `chroot /host` |
| `apply_yaml "<yaml>"` | Pipe inline YAML string to `oc apply -f -` |

---

## assert.sh — Functions

Used only by `run-all.sh` to aggregate results across test scripts.

### State Variables

| Variable | Purpose |
|----------|---------|
| `TESTS_PASSED` | Counter |
| `TESTS_FAILED` | Counter |
| `TESTS_SKIPPED` | Counter |
| `FAILED_TESTS` | Array of failed test names |

### Functions

| Function | Purpose |
|----------|---------|
| `assert_pass <name>` | Print `[PASS]`, increment counter |
| `assert_fail <name> [reason]` | Print `[FAIL]`, increment counter, add to `FAILED_TESTS` |
| `assert_skip <name> [reason]` | Print `[SKIP]`, increment counter |
| `print_summary` | Print pass/fail/skip counts + failed test list. Returns 1 if any failures. |

### How run-all.sh uses it:

```bash
source "$SCRIPT_DIR/../lib/assert.sh"

for test_script in "$SCRIPT_DIR"/test-*.sh; do
  test_name="$(basename "$test_script" .sh)"
  if bash "$test_script"; then
    assert_pass "$test_name"
  else
    assert_fail "$test_name"
  fi
done

print_summary  # exits non-zero if any test failed
```

Note: `assert.sh` depends on color variables (`$GREEN`, `$RED`, etc.) defined in `common.sh`, so `common.sh` must be sourced first.
