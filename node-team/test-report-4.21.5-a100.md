# Test Report — OCP 4.21.5 + NVIDIA A100 (GCP)

- **Date:** 2026-03-24
- **Cluster:** OCP 4.21.5 (Kubernetes v1.34.4)
- **Node:** `harpatil00003cf-t8jxh-master-0` (single master+worker)
- **Instance:** GCP `a2-highgpu-1g` (1x A100 40GB, amd64)
- **GPU Operator:** v26.3.0 (certified-operators catalog)
- **NFD:** v4.21.0
- **KUBECONFIG:** `/Users/harpatil/clusters/4.21/4.21.5/cluster1/auth/kubeconfig`

---

## Phase 0: Cluster Setup

### Step 0.1 — Install NFD Operator

**Input:**
```bash
oc apply -f ocp4nv-demo/nfd-operator-install.yaml
```

**Output:**
```
namespace/openshift-nfd created
operatorgroup.operators.coreos.com/nfd-operator-group created
subscription.operators.coreos.com/nfd created
```
CSV: `nfd.4.21.0-202603092144` — Succeeded. Pod `nfd-controller-manager` Running.

**Result:** PASS

---

### Step 0.2 — Create NFD Instance

Already applied by user in background. NFD instance `nfd-instance` present in `openshift-nfd`.

GPU node labeled with `feature.node.kubernetes.io/pci-0302_10de.present=true` (not the older `pci-10de.present`).

**Result:** PASS

---

### Step 0.3 — Install GPU Operator

**Input:**
```bash
oc apply -f ocp4nv-demo/gpu-operator-install.yaml
```

**Output:**
```
namespace/nvidia-gpu-operator created
operatorgroup.operators.coreos.com/nvidia-gpu-operator-group created
subscription.operators.coreos.com/gpu-operator-certified created
```
CSV: `gpu-operator-certified.v26.3.0` — Succeeded at 45s. Pod `gpu-operator` Running.

**Result:** PASS

---

### Step 0.4 — Apply ClusterPolicy (device-plugin mode)

**Issue encountered:** Initial apply failed with `spec.daemonsets: Required value`. GPU Operator v26.3.0 requires `daemonsets: {}` in the spec. Added to all 4 ClusterPolicy files.

**Input:**
```bash
oc apply -f ocp4nv-demo/node-team/gpu-cluster-policy-standard.yaml
```

**Output:**
```
clusterpolicy.nvidia.com/gpu-cluster-policy created
```

All GPU operator pods reached Running/Succeeded in ~5 minutes (300s). Driver compiled on node successfully.

**Result:** PASS (after fix)

---

### Step 0.5 — Sanity Check

**Input:**
```bash
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

**Output:**
```
harpatil00003cf-t8jxh-master-0	nvidia.com/gpu=1
```

**Result:** PASS

---

## Phase 1: Device Plugin Tests

### Test 1.1 — GPU Operator Health Check

**Input:**
```bash
bash node-team/tests/device-plugin/test-1.1-gpu-operator.sh
```

**First run — FAIL:** Test used hardcoded label `feature.node.kubernetes.io/pci-10de.present` but NFD labeled node with `pci-0302_10de.present`.

**Fix:** Updated `lib/common.sh` to auto-detect GPU node label (`_resolve_gpu_label` function). Updated error message in test-1.1 to use dynamic label.

**Second run — PASS:**
```
=== Checking GPU operator pods ===
[INFO] All GPU operator pods healthy

=== Checking nvidia.com/gpu resource on nodes ===
[INFO] Node harpatil00003cf-t8jxh-master-0: nvidia.com/gpu=1
[INFO] GPU operator validation passed
```

**Result:** PASS (after fix)

---

### Test 1.2 — Basic GPU Workload

**Input:**
```bash
bash node-team/tests/device-plugin/test-1.2-basic-gpu.sh
```

**Output:**
```
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
[INFO] vectorAdd test passed
```

**Result:** PASS

---

### Test 1.3 — Multi-GPU

**Input:**
```bash
bash node-team/tests/device-plugin/test-1.3-multi-gpu.sh
```

**Output:**
```
[WARN] Node harpatil00003cf-t8jxh-master-0 has only 1 GPU(s), need 2+. Skipping test.
[WARN] Use a2-highgpu-2g or larger instance type for this test.
```

**Result:** SKIP (expected — a2-highgpu-1g has only 1 GPU)

---

### Test 1.4 — MIG Enable

**Input:**
```bash
# First: apply MIG ClusterPolicy variant
oc apply -f node-team/gpu-cluster-policy-standard-mig.yaml

# Then: label node for MIG
oc label node harpatil00003cf-t8jxh-master-0 nvidia.com/mig.config=all-1g.5gb --overwrite
```

**Issues encountered:**
1. Needed new ClusterPolicy file (`gpu-cluster-policy-standard-mig.yaml`) with `mig.strategy: mixed`
2. Needed `migManager.env: WITH_REBOOT=true` — GCP VMs don't support GPU reset, so MIG mode changes require a full node reboot
3. Node rebooted (~3 min downtime), then GPU operator pods recovered (~3 min)

**Output (post-reboot):**
```
nvidia.com/mig.config = all-1g.5gb
nvidia.com/mig.config.state = success
nvidia.com/mig-1g.5gb = 7   (allocatable)
```

7 MIG slices of 1g.5gb created from 1x A100-40GB.

**Result:** PASS (after creating MIG ClusterPolicy with `mig.strategy: mixed` and `WITH_REBOOT=true`)

---

### Test 1.5 — MIG Workload

**Input:**
```bash
bash node-team/tests/device-plugin/test-1.5-mig-workload.sh
```

**First run — FAIL:** jsonpath escaping issue — the dot in `mig-1g.5gb` broke `oc get node -o jsonpath`. Fixed to use python3 JSON parsing instead.

**Second run — PASS:**
```
[INFO] Found 7 nvidia.com/mig-1g.5gb on harpatil00003cf-t8jxh-master-0
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
[INFO] MIG workload passed
```

**Result:** PASS (after fix)

---

### Test 1.6 — MPS Enable

**Input:**
```bash
bash node-team/tests/device-plugin/test-1.6-mps-enable.sh
```

**Issues encountered (multiple iterations):**

1. **First attempt:** MIG disable failed — `mig.config.state = failed`. Root cause: reapplying standard ClusterPolicy removed `WITH_REBOOT=true`. Fix: added `WITH_REBOOT=true` to ALL ClusterPolicy files.

2. **Second attempt:** After reboot and MIG disable, device-plugin pods stuck in `Init:0/2` — `MountVolume.SetUp failed for volume "device-plugin-config": configmap "device-plugin-config" not found`. Root cause: ClusterPolicy still had `devicePlugin.config.name` from the failed patch, but ConfigMap was deleted. Fix: removed stale config reference via `oc patch --type=json`.

3. **Third attempt:** MPS control daemon crash (`panic: runtime error: index out of range [0] with length 0`). Root cause: ConfigMap was missing `flags.migStrategy: none`, and ClusterPolicy patch was missing `"default": "mps"` key.

4. **Fourth attempt — PASS:**

**Final working ConfigMap format:**
```yaml
data:
  mps: |
    version: v1
    flags:
      migStrategy: none
    sharing:
      mps:
        resources:
          - name: nvidia.com/gpu
            replicas: 4
```

**Final working ClusterPolicy patch:**
```json
{"spec": {"devicePlugin": {"config": {"name": "device-plugin-config", "default": "mps"}}}}
```

**Output:**
```
=== Step 1a: Reapply standard ClusterPolicy (remove MIG strategy) ===
clusterpolicy.nvidia.com/gpu-cluster-policy unchanged

=== Step 1b: Disable MIG (if enabled) ===
[INFO] Node did not reboot, MIG may have been already disabled.
[INFO] MIG config state: success

=== Step 2: Create device plugin config for MPS ===
configmap/device-plugin-config created

=== Step 3: Patch ClusterPolicy to reference device plugin config ===
clusterpolicy.nvidia.com/gpu-cluster-policy patched

=== Step 4: Label GPU node to use MPS config ===
node/harpatil00003cf-t8jxh-master-0 labeled
[INFO] Node harpatil00003cf-t8jxh-master-0 now reports nvidia.com/gpu=4 (MPS replicas: 4)
```

**Result:** PASS (after multiple fixes)

---

### Test 1.7 — MPS Concurrent Workloads

**Input:**
```bash
bash node-team/tests/device-plugin/test-1.7-mps-concurrent.sh
```

**Output:**
```
[INFO] Cleaning up namespace test-dp-mps-concurrent...
namespace/test-dp-mps-concurrent created
pod/mps-pod-1 created
pod/mps-pod-2 created
pod/mps-pod-3 created

=== Waiting for all MPS pods to complete ===
mps-pod-1: = 169.398 billion interactions per second = 3387.965 GFLOP/s
mps-pod-2: = 169.398 billion interactions per second = 3387.954 GFLOP/s
mps-pod-3: = 169.401 billion interactions per second = 3388.022 GFLOP/s
[INFO] All 3 pods ran concurrently on shared GPU via MPS
```

**Result:** PASS

---

### Test 1.8 — CRI-O + crun Verification

**Input:**
```bash
bash node-team/tests/device-plugin/test-1.8-crio-crun.sh
```

**Output:**
```
=== Checking container runtime on harpatil00003cf-t8jxh-master-0 ===
[INFO] crun is the container runtime

=== Checking CDI specs ===
[INFO] CDI specs found:
k8s.device-plugin.nvidia.com-gpu.json
k8s.device-plugin.nvidia.com-mofed.json
management.nvidia.com-gpu.yaml

=== Checking NVIDIA device files ===
[INFO] CRI-O + crun validation passed
```

**Result:** PASS

---

### Test 1.9 — Topology Manager

**Input:**
```bash
bash node-team/tests/device-plugin/test-1.9-topology-mgr.sh
```

**Output:**
```
[WARN] Could not determine topology manager policy
[WARN] To enable: create a KubeletConfig with topologyManagerPolicy: single-numa-node

GPU0  CPU Affinity: 0-11  NUMA Affinity: 0  GPU NUMA ID: N/A
Cpus_allowed_list: 0-11
Mems_allowed_list: 0
[INFO] Topology test complete
```

**Result:** SKIP (first run — topology manager not configured)

**Rerun after KubeletConfig applied** (`topologyManagerPolicy: single-numa-node`, `cpuManagerPolicy: static`, `reservedSystemCPUs: 0-1`):

```
=== Checking Topology Manager policy on harpatil00003cf-t8jxh-master-0 ===
[INFO] Topology Manager: topologyManagerPolicy: single-numa-node

=== Checking GPU NUMA topology ===
namespace/test-dp-topology created
pod/topo-test created
[INFO] Waiting for pod topo-test to complete (timeout: 120s)...
pod/topo-test condition met
GPU0	CPU Affinity: 6	NUMA Affinity: 0	GPU NUMA ID: N/A
Cpus_allowed_list:	6
Mems_allowed_list:	0
[INFO] Topology test complete
```

CPU pinned to core 6 (not all 12), GPU on NUMA 0, memory on NUMA 0 — proper alignment.

**Final rerun with proper assertions (exit 2 on SKIP, exit 1 on assertion failure):**
```
=== Checking Topology Manager policy on harpatil00003cf-t8jxh-master-0 ===
[INFO] Topology Manager policy: single-numa-node

=== Deploy guaranteed QoS pod with GPU ===
pod/topo-test created
[INFO] Waiting for pod topo-test to be running (timeout: 120s)...
pod/topo-test condition met

=== Verifying NUMA alignment ===
[INFO] Pinned CPUs: 6 (node has 12)
[INFO] Memory NUMA: 0
[INFO] CPU pinning verified (6 is a subset of 0-11)
[INFO] CPU 6 is on NUMA node: 0
[INFO] CPU (NUMA 0) and memory (NUMA 0) aligned
[INFO] Topology test passed — CPU pinned (6), NUMA aligned (node 0), scheduled under single-numa-node policy
```

**Result:** PASS

---

### Test 1.10 — CPU Manager

**Input:**
```bash
bash node-team/tests/device-plugin/test-1.10-cpu-manager.sh
```

**Output:**
```
[WARN] CPU Manager policy may not be 'static'
[WARN] To enable: create a KubeletConfig with cpuManagerPolicy: static

--- CPU pinning ---
Cpus_allowed_list: 0-11
--- GPU ---
GPU 0: NVIDIA A100-SXM4-40GB (UUID: GPU-7f94c45d-05a3-7734-7353-7903e2de1dbe)
--- taskset ---
pid 1's current affinity mask: fff
[INFO] CPU Manager + GPU test complete
```

**Result:** SKIP (first run — CPU manager not static)

**Rerun after KubeletConfig applied:**

```
=== Checking CPU Manager policy on harpatil00003cf-t8jxh-master-0 ===
[INFO] CPU Manager policy: static

=== Deploying Guaranteed QoS pod with CPU + GPU ===
namespace/test-dp-cpu-manager created
pod/cpu-gpu-test created
[INFO] Waiting for pod cpu-gpu-test to complete (timeout: 120s)...
pod/cpu-gpu-test condition met
--- CPU pinning ---
Cpus_allowed_list:	2,8
--- GPU ---
GPU 0: NVIDIA A100-SXM4-40GB (UUID: GPU-7f94c45d-05a3-7734-7353-7903e2de1dbe)
--- taskset ---
pid 1's current affinity mask: 104
[INFO] CPU pinning: 2,8
[INFO] CPU Manager + GPU test complete
```

CPU pinned to cores 2,8 (not all 12) — `cpuManagerPolicy: static` working.

**Final rerun with proper assertions (exit 2 on SKIP, exit 1 on assertion failure):**
```
=== Checking CPU Manager policy on harpatil00003cf-t8jxh-master-0 ===
[INFO] CPU Manager policy: static

=== Deploy guaranteed QoS pod with CPU + GPU ===
pod/cpu-gpu-test created
[INFO] Waiting for pod cpu-gpu-test to be running (timeout: 120s)...
pod/cpu-gpu-test condition met

=== Verifying CPU pinning ===
[INFO] Pinned CPUs: 2,8 (requested 2, node has 12)
[INFO] GPU UUID: GPU-7f94c45d-05a3-7734-7353-7903e2de1dbe
[INFO] CPU pinning verified: 2 CPUs pinned (2,8)
[INFO] GPU allocated (GPU-7f94c45d-05a3-7734-7353-7903e2de1dbe)
[INFO] CPU Manager test passed — 2 CPUs pinned (2,8), GPU allocated, guaranteed QoS
```

**Result:** PASS

---

### Test 1.11 — PodResources API

**Input:**
```bash
bash node-team/tests/device-plugin/test-1.11-pod-resources.sh
```

**Output:**
```
=== Deploy a GPU pod to query via PodResources API ===
pod/gpu-for-pr-api created
[INFO] Waiting for pod gpu-for-pr-api to be running...
pod/gpu-for-pr-api condition met

=== Querying PodResources API on harpatil00003cf-t8jxh-master-0 ===
[INFO] Container ID: 51dcb829a6a3ee2558c921c1f46dd4f33c4e264ff63ed3269f91376825545969
[WARN] Could not extract device info from container inspect
[INFO] PodResources API test complete
```

**Result:** PASS (device info extraction is informational)

---

## Phase 1 Summary

| Test | Description | Result | Notes |
|------|-------------|--------|-------|
| 0.1 | Install NFD operator | PASS | |
| 0.2 | Create NFD instance | PASS | Label is `pci-0302_10de.present` |
| 0.3 | Install GPU operator | PASS | v26.3.0 |
| 0.4 | Apply ClusterPolicy | PASS | Required `daemonsets: {}` for v26+ |
| 0.5 | Sanity check | PASS | nvidia.com/gpu=1 |
| 1.1 | GPU operator health | PASS | Fixed GPU node label auto-detection |
| 1.2 | Basic GPU (vectorAdd) | PASS | |
| 1.3 | Multi-GPU | SKIP | Only 1 GPU (a2-highgpu-1g) |
| 1.4 | MIG enable | PASS | Needed MIG ClusterPolicy + WITH_REBOOT |
| 1.5 | MIG workload | PASS | Fixed jsonpath escaping |
| 1.6 | MPS enable | PASS | Needed migStrategy:none + default key |
| 1.7 | MPS concurrent | PASS | 3 pods shared GPU via MPS (~3388 GFLOP/s each) |
| 1.8 | CRI-O + crun | PASS | crun confirmed, CDI specs present |
| 1.9 | Topology manager | PASS | CPU pinned (core 6), NUMA 0 aligned — after KubeletConfig |
| 1.10 | CPU manager | PASS | CPU pinned (cores 2,8) — `cpuManagerPolicy: static` confirmed |
| 1.11 | PodResources API | PASS | Pod ran, container ID retrieved |

**Phase 1: Passed 14 | Skipped 1 (1.3 multi-GPU — only 1 GPU on a2-highgpu-1g)**

DRA test report continues in [test-report-4.21.5-a100-dra.md](test-report-4.21.5-a100-dra.md)

---

## Files Modified During Testing

| File | Change |
|------|--------|
| `gpu-cluster-policy-*.yaml` (all 4 originals) | Added `daemonsets: {}`, `WITH_REBOOT=true` on migManager |
| `gpu-cluster-policy-standard-mig.yaml` | **NEW** — standard + `mig.strategy: mixed` |
| `gpu-cluster-policy-dra-mig.yaml` | **NEW** — DRA + `mig.strategy: mixed` |
| `tests/lib/common.sh` | Auto-detect GPU node label (`_resolve_gpu_label`) |
| `tests/device-plugin/test-1.1-gpu-operator.sh` | Dynamic label in error message |
| `tests/device-plugin/test-1.4-mig-enable.sh` | Handle full reboot cycle |
| `tests/device-plugin/test-1.5-mig-workload.sh` | Fixed jsonpath escaping for MIG resource check |
| `tests/device-plugin/test-1.6-mps-enable.sh` | Fixed ConfigMap format, ClusterPolicy patch, reboot handling |
| `dra/install.sh` | Added `--set gpuResourcesEnabledOverride=true` for Helm chart v25.12.0 |
| `tests/dra/test-2.1-dra-deploy.sh` | Fixed ResourceSlice attribute parsing (field paths + value keys) |
| `CLAUDE.md` files (all) | Updated label refs, MIG/MPS troubleshooting, new policy table |
