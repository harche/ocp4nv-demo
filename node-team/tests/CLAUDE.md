# Test Suite Overview

> Parent doc: [../CLAUDE.md](../CLAUDE.md)

## Structure

```
tests/
├── lib/                    <- shared helpers (see lib/CLAUDE.md)
│   ├── common.sh
│   └── assert.sh
├── device-plugin/          <- OCPNODE-4138 tests (see device-plugin/CLAUDE.md)
│   ├── run-all.sh
│   └── test-1.*.sh
└── dra/                    <- OCPNODE-4170 tests (see dra/CLAUDE.md)
    ├── run-all.sh
    └── test-2.*.sh
```

## Test Conventions

### Every test script follows this pattern:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"   # always sourced

NS="test-<unique-name>"                 # unique namespace per test
cleanup() { cleanup_ns "$NS"; }
trap cleanup EXIT                       # auto-cleanup on exit

# ... test logic ...
# exit 0 = PASS, exit 1 = FAIL
```

### Key rules:

1. **Self-contained** — each test can run independently: `bash tests/dra/test-2.3-full-gpu.sh`
2. **Own namespace** — every test creates a unique namespace and cleans it up via trap
3. **Inline YAML** — pod/claim manifests are embedded in the script via `apply_yaml` heredocs, not separate files
4. **Exit code** — 0 = pass, non-zero = fail
5. **Dependencies** — some tests depend on prior state (e.g., MPS must be enabled). Dependencies are documented in script headers and enforced with pre-checks.

### run-all.sh:

Each test suite has a `run-all.sh` that:
- Sources `lib/common.sh` and `lib/assert.sh`
- Runs every `test-*.sh` in the directory
- Tracks pass/fail per test
- Prints a summary at the end

The test scripts are sorted lexicographically, so `test-1.1` runs before `test-1.2`, etc. This matters because some tests have sequential dependencies (e.g., 1.6 enables MPS, 1.7 uses it).

## Ordering & Dependencies

### Device Plugin (Phase 1):
```
1.1  GPU operator health     <- no deps
1.2  Basic GPU               <- needs operator running
1.3  Multi-GPU               <- needs >=2 GPUs (skips gracefully if not)
1.6  MPS enable              <- enables MPS
1.7  MPS concurrent          <- depends on 1.6 (MPS must be on)
1.8  CRI-O + crun            <- no deps (verification only)
1.9  Topology manager        <- needs KubeletConfig (informational if not set)
1.10 CPU manager             <- needs KubeletConfig (informational if not set)
1.11 PodResources API        <- no deps
```

### DRA (Phase 2):
```
2.1  DRA deploy              <- verifies dra/install.sh worked
2.2  DeviceClass discovery   <- no deps
2.3  Full GPU                <- basic DRA test
2.4  Device sharing          <- basic DRA test
2.6  MPS via DRA             <- no deps
2.7  Attribute selection     <- no deps (uses CEL productName filter)
2.11 Admin access            <- namespace must have admin-access label
2.12 Admin negative          <- namespace must NOT have label
2.13 CRI-O + crun + DRA     <- verification
2.14 kubelet DRA logs        <- verification (better after running other tests)
2.15 Pod lifecycle           <- create/delete cycle
2.16 Topology + DRA          <- needs KubeletConfig (informational)
2.17 PodResources + DRA      <- verification
```

## Environment Variable Overrides

Several tests accept env vars for hardware adaptation:

| Variable | Default | Used by |
|----------|---------|---------|
| `MPS_REPLICAS` | `4` | test-1.6 |
| `GPU_PRODUCT_PATTERN` | `a100` | test-2.7 |
| `GPU_EXPECTED_ARCH` | _(empty)_ | test-2.1 |
| `GPU_EXPECTED_CUDA_CAP` | _(empty)_ | test-2.1 |
| `DRIVER_PREINSTALLED` | `false` | dra/install.sh, dra/uninstall.sh |

### A100 (default — no overrides needed)
```bash
tests/device-plugin/run-all.sh
tests/dra/run-all.sh
```

### GB200 / Voyager (RHCOS4NV)
```bash
export DRIVER_PREINSTALLED=true
export GPU_PRODUCT_PATTERN=gb200
export GPU_EXPECTED_ARCH=Blackwell
export GPU_EXPECTED_CUDA_CAP=10.0.0
tests/device-plugin/run-all.sh
tests/dra/run-all.sh
```

---

## Interpreting run-all.sh Output

The summary at the end looks like:
```
=== Summary ===
[PASS] test-1.1-gpu-operator
[PASS] test-1.2-basic-gpu
[SKIP] test-1.3-multi-gpu
[FAIL] test-1.6-mps-enable
...
Passed: 9  Failed: 1  Skipped: 1
```

- **PASS**: test ran and assertions succeeded
- **SKIP**: test detected a precondition wasn't met and exited 0 (e.g., not enough GPUs for multi-GPU test). A skip is NOT a failure.
- **FAIL**: test ran and an assertion failed (exit non-zero)

If `run-all.sh` itself exits non-zero, at least one test failed.

## What to Do When a Test Fails

1. **Read the test output** — the error message (in red `[ERROR]`) tells you what assertion failed
2. **Check test-specific troubleshooting** — see `device-plugin/CLAUDE.md` or `dra/CLAUDE.md` for known issues per test
3. **Check for leftover state** — a previous test may have left namespaces leaked:
   ```bash
   # Check for leftover namespaces
   oc get ns | grep -E '^test-(dp|dra)-'
   ```
4. **Clean up and retry the single test**:
   ```bash
   # Delete any leftover test namespaces
   oc get ns | grep -E '^test-(dp|dra)-' | awk '{print $1}' | xargs -r oc delete ns
   # Re-run just the failed test
   bash node-team/tests/device-plugin/test-1.6-mps-enable.sh
   ```
5. **If retry fails, diagnose deeper** — check operator pod logs, node state, events. See the troubleshooting sections in the sub-CLAUDE.md files.

## Leftover Test Namespaces

Each test cleans up via `trap cleanup EXIT`, but if a script is killed mid-run (e.g., Ctrl+C during `run-all.sh`), namespaces may leak and hold GPU allocations.

**Detect:**
```bash
oc get ns | grep -E '^test-(dp|dra)-'
```

**Clean up:**
```bash
oc get ns | grep -E '^test-(dp|dra)-' | awk '{print $1}' | xargs -r oc delete ns
```

Always clean up leaked namespaces before retrying tests, as they may hold GPU allocations that prevent new pods from scheduling.
