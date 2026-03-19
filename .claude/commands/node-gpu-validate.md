You are executing the Node team's GPU validation test suite on an OpenShift 4.21 cluster.

**Target hardware:** $ARGUMENTS (if not specified, default to `a100`)

## Instructions

1. Read `node-team/CLAUDE.md` — this is your primary guide. Follow it exactly.
2. Verify all prerequisites (oc logged in, helm installed, nodes Ready, internet access). If any fail, stop and report.
3. Execute the full flow:
   - **Phase 0:** Cluster setup (NFD, GPU operator, ClusterPolicy) — commands are in `node-team/CLAUDE.md`
   - **Phase 1:** `bash node-team/tests/device-plugin/run-all.sh` — see `node-team/tests/device-plugin/CLAUDE.md` for expected results and troubleshooting
   - **Transition:** `bash node-team/dra/install.sh` — see `node-team/dra/CLAUDE.md` for troubleshooting
   - **Phase 2:** `bash node-team/tests/dra/run-all.sh` — see `node-team/tests/dra/CLAUDE.md` for expected results and troubleshooting
4. If a phase fails, read the relevant CLAUDE.md troubleshooting section, diagnose, fix, and retry before moving on.
5. Report a final summary: total tests passed, failed, skipped, and any issues encountered.

## Hardware-specific overrides

If target is `gb200` or `voyager`:
```bash
export GPU_PRODUCT_PATTERN=gb200
export MIG_PROFILE=all-1g.10gb
```

If target is `a100` (default): no overrides needed, defaults are correct.

## Scope

Only operate within `node-team/`. The parent repo files (`nfd-operator-install.yaml`, `gpu-operator-install.yaml`) are read-only inputs for Phase 0 setup. Do not modify them.
