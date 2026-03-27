# Node Team GPU Validation Suite

## What This Is

Test infrastructure for validating NVIDIA GPU support on OpenShift 4.21, covering two Jira stories under epic [OCPNODE-4135](https://redhat.atlassian.net/browse/OCPNODE-4135):

| Jira | What | Tests |
|------|------|-------|
| [OCPNODE-4138](https://redhat.atlassian.net/browse/OCPNODE-4138) | GPU Operator in **device-plugin** mode | `tests/device-plugin/test-1.*.sh` (9 tests) |
| [OCPNODE-4170](https://redhat.atlassian.net/browse/OCPNODE-4170) | NVIDIA **DRA** (Dynamic Resource Allocation) driver | `tests/dra/test-2.*.sh` (13 tests) |

This lives under `node-team/` to avoid disturbing the parent repo (`ocp4nv-demo`), which is owned by a different team and focused on custom RHCOS4NV images for Voyager/GB200 hardware.

## Hardware Targets

- **Primary (now):** GCP `a2-highgpu-2g` — 2x A100 40GB, amd64, standard OCP 4.21
- **Future (Voyager):** GB200 Grace Hopper — aarch64, RHCOS4NV custom image

The test scripts are hardware-agnostic where possible. Hardware-specific bits (CEL selectors) use environment variables for overrides — see `tests/CLAUDE.md` for the full list.

## Architecture

```
node-team/
├── CLAUDE.md                                    <- you are here
├── gpu-cluster-policy-standard.yaml             <- devicePlugin: true  (Phase 1)
├── gpu-cluster-policy-dra.yaml                  <- devicePlugin: false (Phase 2)
├── gpu-cluster-policy-standard-rhcos4nv.yaml    <- same + driver: false (Voyager)
├── gpu-cluster-policy-dra-rhcos4nv.yaml         <- same + driver: false (Voyager)
├── dra/                                         <- DRA driver install/uninstall
│   └── CLAUDE.md                                <- DRA install troubleshooting
└── tests/                                       <- all test scripts
    ├── CLAUDE.md                                <- test conventions, general troubleshooting
    ├── lib/                                     <- shared helpers
    │   └── CLAUDE.md                            <- function reference
    ├── device-plugin/                           <- OCPNODE-4138
    │   └── CLAUDE.md                            <- expected results, device-plugin troubleshooting
    └── dra/                                     <- OCPNODE-4170
        └── CLAUDE.md                            <- expected results, DRA test troubleshooting
```

## ClusterPolicy Variants

All policies install the full GPU Operator stack (driver, toolkit, DCGM, GFD, CDI). They differ in device-plugin mode and driver:

| File | `devicePlugin` | `driver` | Used for |
|------|---------------|----------|----------|
| `gpu-cluster-policy-standard.yaml` | **true** | true | Device-plugin tests — A100/standard RHCOS |
| `gpu-cluster-policy-dra.yaml` | **false** | true | DRA tests — A100/standard RHCOS |
| `gpu-cluster-policy-standard-rhcos4nv.yaml` | **true** | **false** | Device-plugin tests — Voyager/GB200 (driver baked in) |
| `gpu-cluster-policy-dra-rhcos4nv.yaml` | **false** | **false** | DRA tests — Voyager/GB200 (driver baked in) |

**Common settings across all policies:**
- `daemonsets: {}` — required by GPU Operator v26+
- CDI enabled in all (required for DRA, harmless for device-plugin)

The RHCOS4NV variants set `driver.enabled: false` because the NVIDIA driver (590.x) is pre-installed in the OS image.

---

## Interactive Execution Guide

Follow every step in order. **Ask the user for confirmation before each step** using the `AskUserQuestion` tool. Do NOT skip verification steps — they catch problems early. If a step fails, check the relevant CLAUDE.md for troubleshooting before proceeding.

### Interaction Pattern

Use this pattern for every step:

1. **Explain** what you are about to do and why
2. **Ask for confirmation** via `AskUserQuestion` before running any `oc apply`, `helm install`, or destructive command
3. **Execute** only after the user approves
4. **Verify** the result and report status back to the user
5. **Wait for approval** before moving to the next step

You do NOT need to ask before read-only verification commands (`oc get`, `oc wait`, `oc describe`, etc.) — run those automatically to check status.

### Important Patience Notes

- **MPS enable** requires a ConfigMap with `flags.migStrategy: none` and `sharing.mps` config, plus a ClusterPolicy patch with both `config.name` and `config.default` pointing to the ConfigMap key.
- **Driver compilation** on first ClusterPolicy apply takes 3-10 minutes. Poll status periodically rather than timing out early.
- **NFD labeling** takes 30-60s after creating the NFD instance. The GPU label is `pci-0302_10de.present` (3D controller class) on newer NFD versions, not the older `pci-10de.present`. The test library (`lib/common.sh`) auto-detects both via `_resolve_gpu_label`.

### Prerequisites

Before starting, automatically verify ALL of the following (no confirmation needed for read-only checks):

1. **`oc` is logged in with cluster-admin** — run `oc whoami` and `oc auth can-i '*' '*' --all-namespaces` (must return `yes`)
2. **`helm` is installed** — run `helm version` (required for DRA driver in Phase 2)
3. **Cluster workers are Ready** — run `oc get nodes -o wide` and confirm node(s) show `Ready`
4. **GPU hardware present** — run `oc debug node/<node> -- chroot /host lspci | grep -i nvidia` to confirm GPUs exist
5. **Internet access from cluster** — workers must pull images from `nvcr.io` and the catalog

If any prerequisite fails, use `AskUserQuestion` to report which check(s) failed and ask: "Fix and re-check? / Proceed anyway (risky) / Stop"

### Phase 0: Cluster Setup (Operators + ClusterPolicy)

All commands run from the `ocp4nv-demo/` directory (parent of `node-team/`). The YAML files for NFD and GPU operator are in the parent directory.

**Step 0.1 — Install NFD operator:**
> Ask: "Ready to install the NFD operator from the Red Hat catalog? This applies `nfd-operator-install.yaml` (creates namespace, OperatorGroup, Subscription)."

```bash
oc apply -f nfd-operator-install.yaml
```
Then automatically verify the CSV reaches `Succeeded` and the controller pod is Running.

**Step 0.2 — Create NFD instance (labels GPU nodes):**
> Ask: "NFD operator is running. Ready to create the NFD instance? This will discover hardware features and label GPU nodes."

```bash
oc apply -f nfd-instance.yaml
```
Then automatically wait 30-60s and verify GPU nodes are labeled (check both `pci-10de.present` and `pci-0302_10de.present`).

**Step 0.3 — Install GPU operator:**
> Ask: "NFD labeled N GPU node(s). Ready to install the GPU operator from the catalog?"

```bash
oc apply -f gpu-operator-install.yaml
```
Then automatically wait for the CSV to reach `Succeeded`.

**Step 0.4 — Apply ClusterPolicy (device-plugin mode):**
> Ask: "GPU operator CSV succeeded. Ready to apply the ClusterPolicy? This will deploy the driver, toolkit, DCGM, and device-plugin on GPU nodes."

For A100 / standard RHCOS (driver compiled at runtime):
```bash
oc apply -f node-team/gpu-cluster-policy-standard.yaml
```

For Voyager / GB200 / RHCOS4NV (driver pre-installed):
```bash
export DRIVER_PREINSTALLED=true
oc apply -f node-team/gpu-cluster-policy-standard-rhcos4nv.yaml
```
Then automatically poll GPU operator pods until all are Running (up to 10 minutes for driver compilation).

**Step 0.5 — Sanity check (automatic):**
```bash
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```
Report the GPU count per node. Phase 0 is complete when `nvidia.com/gpu > 0` on GPU workers.

After verifying, use `AskUserQuestion`: "Phase 0 setup complete — all GPU operator pods running and GPUs detected. Proceed to Phase 1?" with options: Proceed to Phase 1 / Re-verify setup / Stop

---

### Phase 1: Device Plugin Tests (OCPNODE-4138)

> Ask: "Phase 0 complete — all GPU operator pods are Running and nvidia.com/gpu is advertised. Ready to run device-plugin tests (9 tests)?"

```bash
bash node-team/tests/device-plugin/run-all.sh
```
Report the pass/fail/skip summary. See `tests/device-plugin/CLAUDE.md` for expected results and troubleshooting.

If any test fails, report the failure and ask the user how to proceed before continuing.

**After Phase 1:** Present a results table. If there are failures, use `AskUserQuestion` to ask which failed test(s) to investigate or retry (list each failed test as an option, plus "Retry all failures" and "Skip — proceed to DRA transition"). For each investigated test, diagnose and offer to retry before moving on.

If all tests passed, use `AskUserQuestion`: "Phase 1 passed. Proceed to DRA transition?" with options: Proceed / Re-run Phase 1 / Stop

---

### Transition: Device Plugin to DRA

> Ask: "Device-plugin tests complete (N passed, N failed, N skipped). Ready to transition to DRA mode? This runs `dra/install.sh` which switches the ClusterPolicy and installs the DRA driver via Helm."

```bash
bash node-team/dra/install.sh
```
Takes 3-5 minutes. See `dra/CLAUDE.md` for troubleshooting if it fails.

**After transition:** If install succeeds, use `AskUserQuestion`: "DRA transition complete. Proceed to Phase 2?" If it fails, ask: "DRA install failed. Troubleshoot? / Retry? / Stop"

---

### Phase 2: DRA Tests (OCPNODE-4170)

> Ask: "DRA driver installed and ready. Ready to run DRA tests (13 tests)?"

```bash
bash node-team/tests/dra/run-all.sh
```
Report the pass/fail/skip summary. See `tests/dra/CLAUDE.md` for expected results and troubleshooting.

If any test fails, report the failure and ask the user how to proceed before continuing.

**After Phase 2:** Same interactive pattern as Phase 1 — present results, ask about failures, offer retry/investigate/skip.

After all failures handled, use `AskUserQuestion`: "All phases complete. What next?" with options: Rollback to device-plugin mode / Keep DRA mode / Generate final report

---

### Rollback (optional)

> Ask: "All tests complete. Want to uninstall the DRA driver and roll back to clean state?"

```bash
bash node-team/dra/uninstall.sh
```

---

## Key Concepts

- **Device Plugin mode**: Traditional Kubernetes device plugin. GPUs are `nvidia.com/gpu` extended resources in pod spec `resources.limits`.
- **DRA mode**: Kubernetes Dynamic Resource Allocation (GA in k8s 1.34 / OCP 4.21). GPUs are allocated via `ResourceClaim` objects with CEL selectors. Supports richer features: attribute-based selection, prioritized alternatives, admin access.
- **MPS (Multi-Process Service)**: NVIDIA's GPU sharing mechanism. Multiple processes share a GPU with better isolation than time-slicing. Configured differently in device-plugin mode (ConfigMap) vs DRA mode (GpuConfig in ResourceClaim).
- **CDI (Container Device Interface)**: Standard spec for injecting devices into containers. Used by both crun and the DRA path.

## Important Notes

- All test scripts are self-contained — they source `tests/lib/common.sh` for helpers
- Each test creates and cleans up its own namespace (trap on EXIT)
- Tests exit 0 on pass, non-zero on fail
- `run-all.sh` aggregates results and prints a summary
- The parent repo's files (`gpu-operator-install.yaml`, `nfd-*.yaml`) are referenced but never modified
- Install-config for the GCP cluster is at `/Users/harpatil/clusters/4.21/install-config-gpu.yaml` (a2-highgpu-2g, 3 workers)
