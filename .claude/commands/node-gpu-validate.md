You are executing the Node team's GPU validation test suite on an OpenShift 4.21 cluster.

**Target hardware:** $ARGUMENTS (if not specified, default to `a100`)

## Instructions

1. Read `node-team/CLAUDE.md` — this is your primary guide. Follow it exactly.
2. Verify all prerequisites (oc logged in, helm installed, nodes Ready, internet access). If any fail, stop and report.
3. Execute the full flow interactively — pause at each phase boundary to check in:

   **Phase 0: Cluster Setup**
   - Run NFD, GPU operator, ClusterPolicy setup from `node-team/CLAUDE.md`
   - After setup, use `AskUserQuestion`: "Phase 0 complete. Proceed?" with options: Proceed to Phase 1 / Re-verify setup / Stop

   **Phase 1: Device Plugin Tests**
   - Run `bash node-team/tests/device-plugin/run-all.sh`
   - Present results table (test name, pass/fail/skip)
   - If any failures, use `AskUserQuestion`: "Which failed test to investigate?" (list each failed test + "Retry all failures" + "Skip and proceed to DRA transition")
   - For each investigated test: diagnose using `tests/device-plugin/CLAUDE.md`, then ask: "Retry this test? / Move to next failure / Proceed to transition"

   **Transition: Device Plugin → DRA**
   - Run `bash node-team/dra/install.sh`
   - If install fails, use `AskUserQuestion`: "DRA install failed. What to do?" with options: Troubleshoot / Retry install / Stop
   - On success, ask: "DRA transition complete. Proceed to Phase 2?"

   **Phase 2: DRA Tests**
   - Run `bash node-team/tests/dra/run-all.sh`
   - Present results table
   - If any failures, use `AskUserQuestion`: same pattern as Phase 1 — pick failed tests to investigate/retry
   - After all failures handled, ask: "Phase 2 done. Rollback DRA? / Keep DRA mode? / File Jira bugs for failures?"

4. Report a final summary: total tests passed, failed, skipped, and any issues encountered.

## Hardware-specific overrides

If target is `gb200` or `voyager`:
```bash
export GPU_PRODUCT_PATTERN=gb200
export MIG_PROFILE=all-1g.10gb
```

If target is `a100` (default): no overrides needed, defaults are correct.

## Scope

Only operate within `node-team/`. The parent repo files (`nfd-operator-install.yaml`, `gpu-operator-install.yaml`) are read-only inputs for Phase 0 setup. Do not modify them.
