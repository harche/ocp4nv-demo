# DRA Tests — OCPNODE-4170

> Parent doc: [../CLAUDE.md](../CLAUDE.md) | Jira: [OCPNODE-4170](https://redhat.atlassian.net/browse/OCPNODE-4170)

## Goal

Validate the NVIDIA DRA (Dynamic Resource Allocation) driver on OCP 4.21. DRA is GA in Kubernetes 1.34 (OCP 4.21) — no `TechPreviewNoUpgrade` needed.

## Prerequisites

- Device-plugin tests (OCPNODE-4138) completed
- `dra/install.sh` has been run successfully (transitions ClusterPolicy + helm installs DRA driver)
- DRA driver pods running in `nvidia-dra-driver-gpu` namespace
- ResourceSlices and DeviceClasses exist

## How to Run

Run all tests:
```bash
bash node-team/tests/dra/run-all.sh
```

Run a single test:
```bash
bash node-team/tests/dra/test-2.3-full-gpu.sh
```

## How DRA Differs from Device Plugin

| Aspect | Device Plugin | DRA |
|--------|--------------|-----|
| GPU in pod spec | `resources.limits: nvidia.com/gpu: 1` | `resources.claims: [{name: gpu}]` + `resourceClaims` |
| GPU selection | None (any available GPU) | CEL expressions on device attributes |
| Sharing config | ConfigMap + node labels | Inline in `ResourceClaim` via `GpuConfig` |
| API objects | None (extended resources) | `ResourceClaim`, `ResourceClaimTemplate`, `DeviceClass`, `ResourceSlice` |

## Test Inventory

### DRA Basics (tests 2.1–2.2)

| Test | Script | What it validates |
|------|--------|------------------|
| 2.1 | `test-2.1-dra-deploy.sh` | DRA driver pods running, ResourceSlices published with GPU attributes (productName, memory) |
| 2.2 | `test-2.2-deviceclass.sh` | `gpu.nvidia.com` DeviceClass exists. |

### Core GPU via DRA (tests 2.3–2.4)

| Test | Script | What it validates |
|------|--------|------------------|
| 2.3 | `test-2.3-full-gpu.sh` | `ResourceClaimTemplate` -> full GPU allocation -> vectorAdd passes. The basic "DRA works" test. |
| 2.4 | `test-2.4-device-sharing.sh` | Two containers in one pod share a `ResourceClaim`. Verifies both see the same GPU UUID. |

### MPS via DRA (test 2.6)

| Test | Script | What it validates |
|------|--------|------------------|
| 2.6 | `test-2.6-mps-via-dra.sh` | Deploys pod with `GpuConfig` sharing strategy `MPS` inline in the ResourceClaim. Two containers share GPU via MPS. |

**How MPS works in DRA mode** (different from device plugin):
```yaml
config:
- requests: ["mps-gpu"]
  opaque:
    driver: gpu.nvidia.com
    parameters:
      apiVersion: resource.nvidia.com/v1beta1
      kind: GpuConfig
      sharing:
        strategy: MPS
        mpsConfig:
          defaultActiveThreadPercentage: 50
          defaultPinnedDeviceMemoryLimit: 10Gi
```

### GA DRA Features (tests 2.7–2.12)

These test the three DRA features that are GA in OCP 4.21:

#### Attribute-Based Allocation (OCPSTRAT-2384)

| Test | Script | What it validates |
|------|--------|------------------|
| 2.7 | `test-2.7-attribute-select.sh` | CEL selector filters by `productName` (default pattern: `a100`). Verifies allocated GPU matches. Override with `GPU_PRODUCT_PATTERN` env var for other hardware. |

#### Admin Access (OCPSTRAT-2397)

| Test | Script | What it validates |
|------|--------|------------------|
| 2.11 | `test-2.11-admin-access.sh` | Namespace labeled `resource.k8s.io/admin-access: "true"`. Workload pod uses GPU, admin pod with `adminAccess: true` can also access it. Workload pod is undisturbed. |
| 2.12 | `test-2.12-admin-negative.sh` | Same admin claim but namespace does **not** have the label. Verifies pod stays Pending (claim rejected). |

### Node Runtime Stack (tests 2.13–2.17)

| Test | Script | What it validates |
|------|--------|------------------|
| 2.13 | `test-2.13-crio-crun-dra.sh` | Verifies crun runtime, deploys DRA GPU pod, checks `/dev/nvidia*` injection via CDI, checks CDI specs on node |
| 2.14 | `test-2.14-kubelet-dra.sh` | Searches kubelet journal for DRA registration logs (`NodePrepareResources`, `NodeUnprepareResources`), checks for DRA plugin socket in `/var/lib/kubelet/plugins/` |
| 2.15 | `test-2.15-pod-lifecycle.sh` | Creates DRA GPU pod, records ResourceClaim state, deletes pod, verifies claim released and NodeUnprepareResources logged |
| 2.16 | `test-2.16-topology-dra.sh` | Guaranteed QoS pod with DRA GPU + CPU/memory limits, shows NUMA alignment. Informational if topology manager not configured. |
| 2.17 | `test-2.17-pod-resources-dra.sh` | Deploys DRA GPU pod, checks ResourceClaim allocation status, inspects container for CDI annotations/devices via `crictl inspect` |

## State Machine

```
Start -> [after device-plugin tests, MPS config may exist]
  2.1-2.4: no state change (full GPU tests)
  2.6: no state change (MPS via DRA)
  2.7: no state change (full GPU, attribute select)
  2.11-2.12: no state change (admin access)
  2.13-2.17: no state change (verification tests)
```

## Environment Variables

| Variable | Default | Used by | Purpose |
|----------|---------|---------|---------|
| `GPU_PRODUCT_PATTERN` | `a100` | test-2.7 | CEL regex pattern for productName matching |
| `GPU_EXPECTED_ARCH` | _(empty)_ | test-2.1 | Expected GPU architecture in ResourceSlices (informational) |
| `GPU_EXPECTED_CUDA_CAP` | _(empty)_ | test-2.1 | Expected CUDA compute capability (informational) |

### Adapting for Voyager/GB200

```bash
export DRIVER_PREINSTALLED=true
export GPU_PRODUCT_PATTERN=gb200
export GPU_EXPECTED_ARCH=Blackwell
export GPU_EXPECTED_CUDA_CAP=10.0.0
tests/dra/run-all.sh
```

## Key DRA API Objects

- **ResourceSlice**: Published by the DRA driver. Lists available devices with attributes (productName, UUID, memory, etc.). One per node per driver.
- **DeviceClass**: Cluster-scoped. Names a class of devices (e.g., `gpu.nvidia.com`). Created by the DRA driver.
- **ResourceClaim**: Namespace-scoped. A request for device(s). Can use `exactly` (specific device class + selectors) or `firstAvailable` (prioritized list).
- **ResourceClaimTemplate**: Like ResourceClaim but creates a new claim per pod (cleaned up with the pod).

---

## Expected Results on A100

| Test | Expected |
|------|----------|
| 2.1 | **PASS** — DRA pods running, ResourceSlices show A100 attributes |
| 2.2 | **PASS** — `gpu.nvidia.com` DeviceClass exists |
| 2.3 | **PASS** — vectorAdd via DRA allocation completes |
| 2.4 | **PASS** — both containers see same GPU UUID |
| 2.6 | **PASS** — two containers share GPU via MPS |
| 2.7 | **PASS** — CEL selector matches A100 productName |
| 2.11 | **PASS** if `adminAccess` is supported in OCP 4.21 (see caveat below). |
| 2.12 | **PASS** if `adminAccess` is supported (pod stays Pending in unlabeled ns). |
| 2.13 | **PASS** — crun + CDI injection verified via DRA path |
| 2.14 | **PASS** — kubelet logs show DRA registration; if no `NodePrepareResources` entries found, it prints a warning (not a failure) |
| 2.15 | **PASS** — ResourceClaim released after pod deletion |
| 2.16 | **PASS** — always passes, prints warnings if topology manager not configured (expected) |
| 2.17 | **PASS** — ResourceClaim allocation status confirmed |

### Admin Access caveat (tests 2.11/2.12)

The `adminAccess` field in `ResourceClaim` is a newer DRA feature. If OCP 4.21 does not include it in `resource.k8s.io/v1`, the ResourceClaim will be rejected by the API server with a validation error. If this happens:
- Record the error message
- Mark tests 2.11 and 2.12 as "not applicable — API not available"
- This is NOT a test infrastructure bug — it means the feature isn't GA in this OCP version yet
- Continue with remaining tests (2.13+)

---

## Troubleshooting

### DRA API not available

**Symptom:** `ResourceClaim` or `ResourceClaimTemplate` objects rejected with "the server could not find the requested resource".

**Diagnose:**
```bash
oc api-resources | grep -i resourceclaim
oc get featuregate cluster -o jsonpath='{.spec}'
```

If `resourceclaims` is NOT listed, DRA is not enabled. This means OCP 4.21 still gates DRA behind `TechPreviewNoUpgrade`.

**Fix (WARNING: irreversible, blocks future upgrades):**
```bash
oc patch featuregate cluster --type=merge -p '{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'
```
This triggers a full cluster rollout (all nodes reboot). Wait for completion:
```bash
# This takes 15-30 minutes
timeout=1800; elapsed=0
while [ $elapsed -lt $timeout ]; do
  updating=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "Unknown")
  degraded=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")
  echo "MCP: Updating=$updating Degraded=$degraded"
  if [ "$updating" = "False" ] && [ "$degraded" = "False" ]; then echo "MCP stable"; break; fi
  sleep 30; elapsed=$((elapsed + 30))
done
```
After MCP is stable, re-run `dra/install.sh`.

### Pod stuck Pending (unexpected)

Test 2.10 intentionally creates a Pending pod. For other tests, a Pending pod means something is wrong.

**Diagnose:**
```bash
oc describe pod <pod-name> -n <namespace>
oc get events -n <namespace> --sort-by=.lastTimestamp | tail -10
```

**Common causes:**
- All GPUs allocated by other test namespaces — clean up leftovers:
  ```bash
  oc get ns | grep -E '^test-dra-' | awk '{print $1}' | xargs -r oc delete ns
  ```
- CEL selector doesn't match any device — inspect available attributes:
  ```bash
  oc get resourceslices -o yaml | grep -A5 productName
  ```

### MPS via DRA not working (test 2.6)

**Symptom:** MPS pod containers don't start or crash.

**Diagnose:**
```bash
oc describe pod mps-pod -n test-dra-mps
oc logs mps-pod -c mps-ctr0 -n test-dra-mps
```

**Common causes:**

- **`unknown GPU sharing strategy: MPS`** — the DRA driver has MPS behind a feature gate. The Helm install must include `--set featureGates.MPSSupport=true`. The `dra/install.sh` script handles this.

- **MPS control daemon `FailedCreate` (SCC)** — the DRA driver spawns a separate Deployment for each MPS control daemon using the `default` service account. On OpenShift this SA needs the `privileged` SCC for `hostPID` and `hostPath` access:
  ```bash
  oc adm policy add-scc-to-user privileged -z default -n nvidia-dra-driver-gpu
  ```
  The `dra/install.sh` script handles this. Check events if MPS daemon pods aren't created:
  ```bash
  oc get events -n nvidia-dra-driver-gpu -o json | python3 -c "import sys,json; [print(e['message'][:300]) for e in json.load(sys.stdin)['items'] if 'Failed' in e.get('reason','')]"
  ```

- **MPS daemon stuck / stale state** — failed MPS attempts leave orphaned deployments and stale ResourceClaim preparation state. Clean up and retry:
  ```bash
  oc delete deployments -n nvidia-dra-driver-gpu -l app.kubernetes.io/component=mps-control-daemon
  oc delete pods -n nvidia-dra-driver-gpu --all
  # Wait for DRA pods to restart, then retry test
  ```

- `GpuConfig` API version mismatch — the opaque parameters use `resource.nvidia.com/v1beta1`. If the DRA driver version doesn't support this, check DRA driver logs.

---

## Interactive Test Review

After running `run-all.sh`, present a results table:

| # | Test | Result |
|---|------|--------|
| 1 | test-2.1-dra-deploy | PASS/FAIL/SKIP |
| ... | ... | ... |

If any tests failed, use `AskUserQuestion` to ask: "Which failed test would you like to investigate?" with options listing each failed test, plus:
- Retry all failed tests
- Skip — proceed to wrap-up

For each investigated test:
1. Show the test output/error
2. Check the troubleshooting section above for known causes
3. Use `AskUserQuestion`: "What to do?" with options: Retry this test / Apply suggested fix and retry / Skip this test / Stop
