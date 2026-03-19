# Device Plugin Tests — OCPNODE-4138

> Parent doc: [../CLAUDE.md](../CLAUDE.md) | Jira: [OCPNODE-4138](https://redhat.atlassian.net/browse/OCPNODE-4138)

## Goal

Validate the NVIDIA GPU Operator in **device-plugin mode** on OCP 4.21. This is the traditional Kubernetes device plugin path where GPUs appear as `nvidia.com/gpu` extended resources.

## Prerequisites

- OCP 4.21 cluster with GPU worker nodes (A100 or Voyager)
- NFD operator installed + NFD instance created (node labels applied)
- GPU Operator installed from certified-operators catalog
- `gpu-cluster-policy-standard.yaml` applied (devicePlugin: true)

## How to Run

Run all tests:
```bash
bash node-team/tests/device-plugin/run-all.sh
```

Run a single test:
```bash
bash node-team/tests/device-plugin/test-1.2-basic-gpu.sh
```

## Test Inventory

### Core GPU (tests 1.1–1.3)

| Test | Script | What it does | Cleanup |
|------|--------|-------------|---------|
| 1.1 | `test-1.1-gpu-operator.sh` | Verifies all GPU operator pods running, `nvidia.com/gpu` resource advertised on GPU nodes | None (read-only) |
| 1.2 | `test-1.2-basic-gpu.sh` | Runs `vectoradd-cuda11.6.0` pod with `nvidia.com/gpu: 1` | Deletes ns `test-dp-basic-gpu` |
| 1.3 | `test-1.3-multi-gpu.sh` | Pod with `nvidia.com/gpu: 2`, checks it sees exactly 2 GPUs. **Skips gracefully** if node has < 2 GPUs. | Deletes ns `test-dp-multi-gpu` |

### MIG (tests 1.4–1.5)

These modify node state. 1.4 enables MIG, 1.5 uses it.

| Test | Script | What it does | Side effects |
|------|--------|-------------|-------------|
| 1.4 | `test-1.4-mig-enable.sh` | Labels node with `nvidia.com/mig.config=all-1g.5gb`, waits for MIG manager to create slices, verifies `nvidia.com/mig-1g.5gb` resources appear | **Enables MIG on GPU** (persists) |
| 1.5 | `test-1.5-mig-workload.sh` | Runs vectorAdd requesting `nvidia.com/mig-1g.5gb: 1` | Deletes ns `test-dp-mig-workload` |

**MIG profiles on A100-40GB:** `1g.5gb` (x7), `2g.10gb` (x3), `3g.20gb` (x2), `4g.20gb` (x1), `7g.40gb` (x1). Override with `MIG_PROFILE` env var.

### MPS (tests 1.6–1.7)

1.6 disables MIG first, then enables MPS. 1.7 runs concurrent workloads.

| Test | Script | What it does | Side effects |
|------|--------|-------------|-------------|
| 1.6 | `test-1.6-mps-enable.sh` | Disables MIG, creates device-plugin ConfigMap for MPS (4 replicas), patches ClusterPolicy, labels node, verifies `nvidia.com/gpu` count increases | **Modifies ClusterPolicy** + creates ConfigMap |
| 1.7 | `test-1.7-mps-concurrent.sh` | Deploys 3 pods each requesting `nvidia.com/gpu: 1`, verifies all run concurrently (only possible with MPS/time-slicing) | Deletes ns `test-dp-mps-concurrent` |

**How MPS works in device-plugin mode:**
1. A ConfigMap (`device-plugin-config` in `nvidia-gpu-operator` ns) defines the sharing strategy
2. The GPU node is labeled `nvidia.com/device-plugin.config=<config-key>`
3. The ClusterPolicy is patched to reference the ConfigMap
4. The device plugin restarts and advertises `nvidia.com/gpu` with the replica count

### Node Runtime Stack (tests 1.8–1.11)

These are mostly verification/informational tests.

| Test | Script | What it does |
|------|--------|-------------|
| 1.8 | `test-1.8-crio-crun.sh` | Checks crun is the runtime via `crictl info`, verifies CDI specs exist in `/var/run/cdi/` or `/etc/cdi/`, checks `/dev/nvidia*` device files |
| 1.9 | `test-1.9-topology-mgr.sh` | Checks topology manager policy in kubelet config, deploys guaranteed QoS GPU pod, shows NUMA alignment info. Requires `KubeletConfig` with `topologyManagerPolicy: single-numa-node` for full validation. |
| 1.10 | `test-1.10-cpu-manager.sh` | Checks CPU manager policy, deploys guaranteed QoS pod with CPU + GPU, shows CPU pinning via `/proc/self/status`. Requires `cpuManagerPolicy: static`. |
| 1.11 | `test-1.11-pod-resources.sh` | Deploys a GPU pod, queries PodResources API via kubelet socket and/or `crictl inspect` to verify GPU allocation is reported |

**Note on 1.9 and 1.10:** These tests are informational if the KubeletConfig isn't set to static/single-numa-node. They won't fail, but they'll print warnings. To fully validate, create a `KubeletConfig` CR targeting GPU workers (this causes a node reboot via MCP rollout).

## State Machine

The tests modify node state in this sequence:

```
Start -> [default, no MIG]
  1.1-1.3: no state change
  1.4: MIG ON (all-1g.5gb)
  1.5: uses MIG
  1.6: MIG OFF -> MPS ON
  1.7: uses MPS
  1.8-1.11: no state change (MPS still on)
```

After all tests, MPS config remains. The DRA transition (`dra/install.sh`) handles cleanup.

---

## Expected Results on A100

| Test | Expected |
|------|----------|
| 1.1 | **PASS** — GPU operator pods healthy, `nvidia.com/gpu` advertised |
| 1.2 | **PASS** — vectorAdd completes with "Test PASSED" |
| 1.3 | **PASS** on `a2-highgpu-2g` (2 GPUs), **SKIP** on `a2-highgpu-1g` (1 GPU). A skip is NOT a failure. |
| 1.4 | **PASS** — MIG resources appear within ~5 minutes |
| 1.5 | **PASS** — vectorAdd on MIG slice completes |
| 1.6 | **PASS** — `nvidia.com/gpu` count increases to MPS replica count |
| 1.7 | **PASS** — 3 pods run concurrently sharing GPU |
| 1.8 | **PASS** — crun detected, CDI specs present |
| 1.9 | **PASS** — always passes, prints warnings if topology manager not configured (expected, not a problem) |
| 1.10 | **PASS** — always passes, prints warnings if CPU manager not static (expected, not a problem) |
| 1.11 | **PASS** — PodResources API reports GPU allocation |

---

## Troubleshooting

### GPU operator pods not starting

**Symptom:** Pods in `nvidia-gpu-operator` namespace stuck in `Init`, `CrashLoopBackOff`, or `ImagePullBackOff`.

**Diagnose:**
```bash
oc get pods -n nvidia-gpu-operator
oc describe pod <failing-pod> -n nvidia-gpu-operator
oc logs <failing-pod> -n nvidia-gpu-operator --all-containers
```

**Common causes:**
- `ImagePullBackOff`: cluster can't pull from `nvcr.io` — check node internet access and pull secret
- `nvidia-driver-daemonset` crash: driver compilation failed — check logs for kernel header mismatches. On standard OCP 4.21 with stock kernel this should not happen.
- `nvidia-device-plugin-validation` fails: GPU not accessible — verify GPU exists on the node:
  ```bash
  oc debug node/<GPU_NODE> -- chroot /host lspci | grep -i nvidia
  ```

### MIG reconfiguration stuck (test 1.4)

**Symptom:** After labeling node with `nvidia.com/mig.config=all-1g.5gb`, MIG resources never appear in node allocatable.

**Diagnose:**
```bash
GPU_NODE=$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o jsonpath='{.items[0].metadata.name}')
oc logs -n nvidia-gpu-operator $(oc get pods -n nvidia-gpu-operator -l app=nvidia-mig-manager -o name | head -1)
oc get node $GPU_NODE -o jsonpath='{.metadata.labels}' | python3 -m json.tool | grep mig
```

**Common causes:**
- MIG manager pod not running — check `oc get pods -n nvidia-gpu-operator | grep mig`
- MIG config label typo — must be exactly `nvidia.com/mig.config`, value must be a valid profile like `all-1g.5gb`

**Fix:** Reset and retry:
```bash
oc label node $GPU_NODE nvidia.com/mig.config=all-disabled --overwrite
sleep 60
oc label node $GPU_NODE nvidia.com/mig.config=all-1g.5gb --overwrite
```

### MPS not working (tests 1.6/1.7)

**Symptom:** After MPS enable, `nvidia.com/gpu` count doesn't increase to the replica count.

**Diagnose:**
```bash
oc get configmap device-plugin-config -n nvidia-gpu-operator -o yaml
oc get pods -n nvidia-gpu-operator | grep device-plugin
oc logs -n nvidia-gpu-operator $(oc get pods -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset -o name | head -1)
GPU_NODE=$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o jsonpath='{.items[0].metadata.name}')
oc get node $GPU_NODE --show-labels | grep device-plugin.config
```

**Common causes:**
- ConfigMap format mismatch with GPU operator version — different versions use different schemas
- Device plugin pod didn't restart after ConfigMap change — force restart:
  ```bash
  oc delete pod -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset
  ```
- Node not labeled — verify `nvidia.com/device-plugin.config=mps` label exists

### Pod stuck Pending

**Symptom:** A test pod stays Pending when it should be Running.

**Diagnose:**
```bash
oc describe pod <pod-name> -n <namespace>    # check Events section
oc get events -n <namespace> --sort-by=.lastTimestamp | tail -10
```

**Common causes:**
- `Insufficient nvidia.com/gpu`: all GPUs allocated — check for leftover test namespaces: `oc get ns | grep test-dp-`
- MIG still enabled when test expects full GPU — reset: `oc label node $GPU_NODE nvidia.com/mig.config=all-disabled --overwrite`
