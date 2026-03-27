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

### MPS (tests 1.6–1.7)

1.6 enables MPS. 1.7 runs concurrent workloads.

| Test | Script | What it does | Side effects |
|------|--------|-------------|-------------|
| 1.6 | `test-1.6-mps-enable.sh` | Creates device-plugin ConfigMap for MPS (4 replicas), patches ClusterPolicy, labels node, verifies `nvidia.com/gpu` count increases | **Modifies ClusterPolicy** + creates ConfigMap |
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
Start -> [default]
  1.1-1.3: no state change
  1.6: MPS ON
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

### MPS not working (tests 1.6/1.7)

**Symptom:** After MPS enable, `nvidia.com/gpu` count doesn't increase to the replica count.

**Diagnose:**
```bash
oc get configmap device-plugin-config -n nvidia-gpu-operator -o yaml
oc get pods -n nvidia-gpu-operator | grep device-plugin
oc logs -n nvidia-gpu-operator $(oc get pods -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset -o name | head -1)
GPU_NODE=$(oc get nodes -l feature.node.kubernetes.io/pci-0302_10de.present=true -o jsonpath='{.items[0].metadata.name}')
oc get node $GPU_NODE --show-labels | grep device-plugin.config
```

**Common causes:**
- **ConfigMap missing `flags.migStrategy: none`** — the MPS config must include `flags: migStrategy: none` alongside the `sharing.mps` block
- **ClusterPolicy patch missing `default` key** — the patch must include both `config.name` and `config.default` pointing to the ConfigMap data key (e.g., `"default": "mps"`)
- **MPS control daemon crash** — if you see `panic: runtime error: index out of range` in the MPS control daemon logs, clean up and reapply: delete the ConfigMap, remove the `device-plugin.config` label, remove `devicePlugin.config` from ClusterPolicy, then redo the steps in order
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

---

## Interactive Test Review

After running `run-all.sh`, present a results table:

| # | Test | Result |
|---|------|--------|
| 1 | test-1.1-gpu-operator | PASS/FAIL/SKIP |
| ... | ... | ... |

If any tests failed, use `AskUserQuestion` to ask: "Which failed test would you like to investigate?" with options listing each failed test, plus:
- Retry all failed tests
- Skip — proceed to next phase

For each investigated test:
1. Show the test output/error
2. Check the troubleshooting section above for known causes
3. Use `AskUserQuestion`: "What to do?" with options: Retry this test / Apply suggested fix and retry / Skip this test / Stop
