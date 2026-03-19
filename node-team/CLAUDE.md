# Node Team GPU Validation Suite

## What This Is

Test infrastructure for validating NVIDIA GPU support on OpenShift 4.21, covering two Jira stories under epic [OCPNODE-4135](https://redhat.atlassian.net/browse/OCPNODE-4135):

| Jira | What | Tests |
|------|------|-------|
| [OCPNODE-4138](https://redhat.atlassian.net/browse/OCPNODE-4138) | GPU Operator in **device-plugin** mode | `tests/device-plugin/test-1.*.sh` (11 tests) |
| [OCPNODE-4170](https://redhat.atlassian.net/browse/OCPNODE-4170) | NVIDIA **DRA** (Dynamic Resource Allocation) driver | `tests/dra/test-2.*.sh` (17 tests) |

This lives under `node-team/` to avoid disturbing the parent repo (`ocp4nv-demo`), which is owned by a different team and focused on custom RHCOS4NV images for Voyager/GB200 hardware.

## Hardware Targets

- **Primary (now):** GCP `a2-highgpu-2g` — 2x A100 40GB, amd64, standard OCP 4.21
- **Future (Voyager):** GB200 Grace Hopper — aarch64, RHCOS4NV custom image

The test scripts are hardware-agnostic where possible. Hardware-specific bits (CEL selectors, MIG profiles) use environment variables for overrides — see `tests/CLAUDE.md` for the full list.

## Architecture

```
node-team/
├── CLAUDE.md                          <- you are here
├── gpu-cluster-policy-standard.yaml   <- devicePlugin: true  (Phase 1)
├── gpu-cluster-policy-dra.yaml        <- devicePlugin: false (Phase 2)
├── dra/                               <- DRA driver install/uninstall
│   └── CLAUDE.md                      <- DRA install troubleshooting
└── tests/                             <- all test scripts
    ├── CLAUDE.md                      <- test conventions, general troubleshooting
    ├── lib/                           <- shared helpers
    │   └── CLAUDE.md                  <- function reference
    ├── device-plugin/                 <- OCPNODE-4138
    │   └── CLAUDE.md                  <- expected results, device-plugin troubleshooting
    └── dra/                           <- OCPNODE-4170
        └── CLAUDE.md                  <- expected results, DRA test troubleshooting
```

## Two ClusterPolicy Variants

Both policies install the full GPU Operator stack (driver, toolkit, DCGM, GFD, MIG manager, CDI). The only difference:

| File | `devicePlugin` | `cdi` | Used for |
|------|---------------|-------|----------|
| `gpu-cluster-policy-standard.yaml` | **true** | true | Device-plugin tests (Phase 1) |
| `gpu-cluster-policy-dra.yaml` | **false** | true | DRA tests (Phase 2) |

CDI is enabled in both because the DRA path requires it, and it doesn't hurt device-plugin mode.

---

## Autonomous Execution Guide

Follow every step in order. Do NOT skip verification steps — they catch problems early. If a step fails, check the relevant CLAUDE.md for troubleshooting before proceeding.

### Prerequisites

Before starting, verify ALL of the following:

1. **`oc` is logged in with cluster-admin** — run `oc whoami` and `oc auth can-i '*' '*' --all-namespaces` (must return `yes`)
2. **`helm` is installed** — run `helm version` (required for DRA driver in Phase 2)
3. **Cluster workers are Ready with A100 GPUs** — run `oc get nodes` and confirm GPU worker nodes show `Ready`
4. **Internet access from cluster** — workers must pull images from `nvcr.io` (NVIDIA container registry) and the GPU operator downloads drivers from the catalog

If any prerequisite fails, stop and report the issue.

### Phase 0: Cluster Setup (Operators + ClusterPolicy)

All commands run from the `ocp4nv-demo/` directory (parent of `node-team/`). The YAML files for NFD and GPU operator are in the parent directory.

**Step 0.1 — Install NFD operator:**
```bash
oc apply -f nfd-operator-install.yaml
oc wait --for=condition=Available deployment -l app.kubernetes.io/name=node-feature-discovery-operator \
  -n openshift-nfd --timeout=300s
```

**Step 0.2 — Create NFD instance (labels GPU nodes):**
```bash
oc apply -f nfd-instance.yaml
sleep 30
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true
```
**Verify:** At least one node listed. If none, wait 30s more and retry. If still nothing, nodes don't have GPUs — check instance type with `oc get nodes -o wide`.

**Step 0.3 — Install GPU operator:**
```bash
oc apply -f gpu-operator-install.yaml
```
Wait for CSV:
```bash
timeout=300; elapsed=0
while [ $elapsed -lt $timeout ]; do
  phase=$(oc get csv -n nvidia-gpu-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Waiting")
  if [ "$phase" = "Succeeded" ]; then echo "CSV succeeded"; break; fi
  sleep 10; elapsed=$((elapsed + 10))
done
```

**Step 0.4 — Apply ClusterPolicy (device-plugin mode):**
```bash
oc apply -f node-team/gpu-cluster-policy-standard.yaml
```
Wait for GPU operator pods (3-10 minutes — driver downloads and compiles on each GPU node):
```bash
timeout=600; elapsed=0
while [ $elapsed -lt $timeout ]; do
  not_ready=$(oc get pods -n nvidia-gpu-operator --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | wc -l | tr -d ' ')
  total=$(oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "GPU operator pods: $((total - not_ready))/$total ready"
  if [ "$not_ready" -eq 0 ] && [ "$total" -gt 0 ]; then break; fi
  sleep 15; elapsed=$((elapsed + 15))
done
```
If pods fail, see `tests/device-plugin/CLAUDE.md` > Troubleshooting > GPU operator pods not starting.

**Step 0.5 — Sanity check:**
```bash
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```
**Verify:** Each GPU worker shows `nvidia.com/gpu` = 1 or 2 (depending on instance type). If 0 or missing, wait and recheck.

**Phase 0 is complete when:** all GPU operator pods are Running AND `nvidia.com/gpu > 0` on GPU workers.

---

### Phase 1: Device Plugin Tests (OCPNODE-4138)

```bash
bash node-team/tests/device-plugin/run-all.sh
```
Runs 11 tests (1.1–1.11), prints pass/fail/skip summary. See `tests/device-plugin/CLAUDE.md` for expected results and troubleshooting.

---

### Transition: Device Plugin to DRA

```bash
bash node-team/dra/install.sh
```
Takes 3-5 minutes. See `dra/CLAUDE.md` for troubleshooting if it fails.

---

### Phase 2: DRA Tests (OCPNODE-4170)

```bash
bash node-team/tests/dra/run-all.sh
```
Runs 17 tests (2.1–2.17), prints pass/fail/skip summary. See `tests/dra/CLAUDE.md` for expected results and troubleshooting.

---

### Rollback (optional)

```bash
bash node-team/dra/uninstall.sh
```

---

## Key Concepts

- **Device Plugin mode**: Traditional Kubernetes device plugin. GPUs are `nvidia.com/gpu` extended resources in pod spec `resources.limits`.
- **DRA mode**: Kubernetes Dynamic Resource Allocation (GA in k8s 1.34 / OCP 4.21). GPUs are allocated via `ResourceClaim` objects with CEL selectors. Supports richer features: attribute-based selection, prioritized alternatives, admin access.
- **MIG (Multi-Instance GPU)**: A100/H100 feature. Partitions one GPU into isolated slices (e.g., 7x `1g.5gb` on A100-40GB). Managed by GPU Operator's MIG manager via node label `nvidia.com/mig.config`.
- **MPS (Multi-Process Service)**: NVIDIA's GPU sharing mechanism. Multiple processes share a GPU with better isolation than time-slicing. Configured differently in device-plugin mode (ConfigMap) vs DRA mode (GpuConfig in ResourceClaim).
- **CDI (Container Device Interface)**: Standard spec for injecting devices into containers. Used by both crun and the DRA path.

## Important Notes

- All test scripts are self-contained — they source `tests/lib/common.sh` for helpers
- Each test creates and cleans up its own namespace (trap on EXIT)
- Tests exit 0 on pass, non-zero on fail
- `run-all.sh` aggregates results and prints a summary
- The parent repo's files (`gpu-operator-install.yaml`, `nfd-*.yaml`) are referenced but never modified
- Install-config for the GCP cluster is at `/Users/harpatil/clusters/4.21/install-config-gpu.yaml` (a2-highgpu-2g, 3 workers)
