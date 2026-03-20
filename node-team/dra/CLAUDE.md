# DRA Driver Setup

> Parent doc: [../CLAUDE.md](../CLAUDE.md)

## What This Does

Manages the transition between device-plugin mode and DRA mode on the cluster. This is not a simple install — it requires changing the ClusterPolicy first, because the NVIDIA device plugin and DRA driver cannot manage GPUs simultaneously.

## Files

| File | Purpose |
|------|---------|
| `install.sh` | Transition to DRA mode + install DRA driver |
| `uninstall.sh` | Remove DRA driver + restore device-plugin mode |

## install.sh — Step by Step

1. **Apply `gpu-cluster-policy-dra.yaml`** — sets `devicePlugin.enabled: false`
2. **Wait for device-plugin pods to terminate** — GPU Operator reconciles and removes them
3. **Wait for nodes to be Ready** — nodes may restart pods
4. **Add NVIDIA helm repo** — `helm.ngc.nvidia.com/nvidia`
5. **Helm install `nvidia-dra-driver-gpu`** — into namespace `nvidia-dra-driver-gpu`
6. **Verify** — checks DRA pods running, ResourceSlices published, DeviceClasses exist

## Helm Chart Details

| Parameter | Value | Why |
|-----------|-------|-----|
| Chart | `nvidia/nvidia-dra-driver-gpu` | Official NVIDIA DRA driver |
| Version | `25.12.0` (default, override via `DRA_CHART_VERSION` env var) | Latest stable at time of writing |
| `nvidiaDriverRoot` | `/run/nvidia/driver` | **Required for OpenShift** when GPU Operator manages the driver (not host-installed) |
| Namespace | `nvidia-dra-driver-gpu` | Created automatically |

### Why `nvidiaDriverRoot=/run/nvidia/driver`?

On OpenShift with the GPU Operator, the NVIDIA driver is not installed on the host at `/`. Instead, the driver container mounts it at `/run/nvidia/driver`. The DRA driver needs this path to find `libnvidia-ml.so` and GPU device files. Setting this incorrectly is the **most common installation failure**.

## uninstall.sh — Step by Step

1. Helm uninstall the DRA driver
2. Delete the DRA namespace
3. Re-apply `gpu-cluster-policy-standard.yaml` (re-enables device plugin)
4. Wait for GPU Operator to reconcile and nodes to be Ready

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `DRA_CHART_VERSION` | `25.12.0` | Override helm chart version |

---

## Verifying a Successful Install

After `install.sh` completes, verify these three things:

**1. DRA pods running:**
```bash
oc get pods -n nvidia-dra-driver-gpu
```
Expected: all pods in `Running` state. There should be one pod per GPU node.

**2. ResourceSlices published:**
```bash
oc get resourceslices
```
Expected: at least one ResourceSlice per GPU node. Inspect attributes:
```bash
oc get resourceslices -o yaml | grep -E 'productName|architecture|memory'
```

**3. DeviceClasses exist:**
```bash
oc get deviceclasses
```
Expected: `gpu.nvidia.com` exists. `mig.nvidia.com` will appear after MIG is enabled.

---

## Troubleshooting

### DRA pods CrashLooping

**Symptom:** Pods in `nvidia-dra-driver-gpu` namespace restart repeatedly.

**Diagnose:**
```bash
oc get pods -n nvidia-dra-driver-gpu
oc logs -n nvidia-dra-driver-gpu $(oc get pods -n nvidia-dra-driver-gpu -o name | head -1) --all-containers
oc describe pod -n nvidia-dra-driver-gpu $(oc get pods -n nvidia-dra-driver-gpu -o name | head -1)
```

**Common causes:**
- **Wrong `nvidiaDriverRoot`**: The DRA driver can't find `libnvidia-ml.so`. Fix: re-install with correct path (the script already uses `/run/nvidia/driver`, so this shouldn't happen unless manually overridden).
- **NVIDIA driver not running**: The GPU Operator driver pod must be healthy. Check:
  ```bash
  oc get pods -n nvidia-gpu-operator | grep driver
  oc logs -n nvidia-gpu-operator $(oc get pods -n nvidia-gpu-operator -l app=nvidia-driver-daemonset -o name | head -1)
  ```
- **Helm chart version incompatible**: Try a different version:
  ```bash
  bash node-team/dra/uninstall.sh
  DRA_CHART_VERSION=25.6.0 bash node-team/dra/install.sh
  ```

### No ResourceSlices after install

**Symptom:** DRA pods are Running but `oc get resourceslices` returns nothing.

**Diagnose:**
```bash
oc logs -n nvidia-dra-driver-gpu $(oc get pods -n nvidia-dra-driver-gpu -o name | head -1) --all-containers 2>&1 | tail -30
```

**Common causes:**
- DRA driver can't enumerate GPUs — verify GPU is accessible on the node:
  ```bash
  GPU_NODE=$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o jsonpath='{.items[0].metadata.name}')
  oc debug node/$GPU_NODE -- chroot /host nvidia-smi
  ```
  If `nvidia-smi` fails, the NVIDIA driver isn't working. Fix the GPU Operator first.
- DRA driver started before device-plugin fully terminated — restart DRA pods:
  ```bash
  oc delete pods -n nvidia-dra-driver-gpu --all
  sleep 30
  oc get resourceslices
  ```

### DeviceClasses missing

**Symptom:** `oc get deviceclasses` returns nothing or only `gpu.nvidia.com` is missing.

The DRA driver creates DeviceClasses on startup. If they're missing, the driver didn't start correctly. Check the DRA pod logs (same as "DRA pods CrashLooping" above).

---

## Interactive Verification

After `install.sh` completes, check all three verification steps (DRA pods, ResourceSlices, DeviceClasses). If any fail, use `AskUserQuestion` to ask: "DRA install verification failed — [which check]. What to do?" with options:
- Troubleshoot (diagnose using sections above)
- Retry install (uninstall + reinstall)
- Try different chart version
- Stop

### Helm install fails

**Symptom:** `helm install` returns an error.

**Common causes:**
- `helm` not installed — install it: `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash`
- Helm repo not reachable — check internet: `curl -s https://helm.ngc.nvidia.com/nvidia/index.yaml | head -5`
- Namespace already exists from a previous attempt — uninstall first:
  ```bash
  bash node-team/dra/uninstall.sh
  bash node-team/dra/install.sh
  ```

### Device-plugin pods don't terminate after ClusterPolicy change

**Symptom:** `install.sh` waits but device-plugin pods remain.

**Diagnose:**
```bash
oc get pods -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset
oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.spec.devicePlugin.enabled}'
```

If `devicePlugin.enabled` is `false` but pods remain, the GPU Operator hasn't reconciled yet.

**Fix:** Wait longer (up to 5 minutes), or restart the GPU Operator:
```bash
oc delete pod -n nvidia-gpu-operator -l app=gpu-operator
sleep 30
```

## Reference

- [NVIDIA DRA driver OpenShift README](https://github.com/NVIDIA/k8s-dra-driver-gpu/blob/main/demo/clusters/openshift/README.md)
- [NVIDIA DRA driver Installation Guide (wiki)](https://github.com/NVIDIA/k8s-dra-driver-gpu/wiki/Installation)
