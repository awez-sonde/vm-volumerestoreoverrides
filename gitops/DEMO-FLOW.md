# Demo flow (simple)

You are **not** running everything in one Application. There are **three demo Applications** (plus one installer).

## The four Argo CD Applications

| Application | Role in the demo | You sync it when… |
|-------------|------------------|-------------------|
| `volume-restore-overrides-demo` | **Installer only** — creates the AppProject and the 3 apps below | Once, at setup (`oc apply -f gitops/bootstrap/...`) |
| `fedora-demo-vm` | **Step 1 — Create VM** | VM should exist and be Ready |
| `fedora-demo-snapshot` | **Step 2 — Create snapshot** | VM is Ready; you are ready to snapshot |
| `fedora-demo-restore` | **Step 4 — Restore VM** | After drift + VM is **Halted** and snapshot is ready |
| *(no Application)* | **Step 3 — Add drift** | Manual `oc` / SSH (change the web page) |

**Step 3 is intentionally not GitOps.** Changing the page inside the VM is a manual “something changed after the snapshot” step, like in the original README.

## Flow diagram

```
  [Setup]
      │
      ▼
  bootstrap app installs ──► fedora-demo-vm app
                             fedora-demo-snapshot app
                             fedora-demo-restore app

  [Demo — you control the timing]

  1. Sync fedora-demo-vm          ──► Namespace + VM in vm-volume-restore-demo
            │
            ▼
  2. Sync fedora-demo-snapshot    ──► VirtualMachineSnapshot
            │
            ▼
  3. Manual drift (oc / SSH)      ──► Change /var/www/html/index.html
            │
            ▼
     Halt VM (oc patch)
            │
            ▼
  4. Sync fedora-demo-restore     ──► VirtualMachineRestore + volumeRestoreOverrides
            │
            ▼
     Start VM (oc patch) + verify page restored
```

## What each Application deploys

| Application | Manifest | Result in cluster |
|-------------|----------|-------------------|
| `fedora-demo-vm` | `fedora-demo-vm.yaml` | `Namespace` + `VirtualMachine` |
| `fedora-demo-snapshot` | `snapshot.yaml` | `VirtualMachineSnapshot` |
| `fedora-demo-restore` | `restore-with-overrides.yaml` | `VirtualMachineRestore` |

Each app points at **one** overlay folder and **one** root file. They do not share a single sync that does VM + snapshot + restore together.

## Commands per step

```bash
NS=vm-volume-restore-demo

# Step 1 — create VM (Argo CD UI: Sync "fedora-demo-vm", or CLI:)
oc patch application fedora-demo-vm -n openshift-gitops \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
oc wait vm/fedora-demo -n $NS --for=condition=Ready --timeout=300s

# Step 2 — snapshot
oc patch application fedora-demo-snapshot -n openshift-gitops \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
oc wait virtualmachinesnapshot/fedora-demo-snap -n $NS \
  --for=jsonpath='{.status.readyToUse}'=true --timeout=120s

# Step 3 — drift (manual — see root README)
VM_IP=$(oc get vmi fedora-demo -n $NS -o jsonpath='{.status.interfaces[0].ipAddress}')
# ... curl original page, SSH change page, curl modified page ...

# Halt before restore
oc patch vm fedora-demo -n $NS --type merge -p '{"spec":{"runStrategy":"Halted"}}'
oc wait vmi/fedora-demo -n $NS --for=delete --timeout=300s

# Step 4 — restore
oc patch application fedora-demo-restore -n openshift-gitops \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
oc wait virtualmachinerestore/fedora-demo-restore -n $NS \
  --for=jsonpath='{.status.complete}'=true --timeout=120s

# Start VM and verify
oc patch vm fedora-demo -n $NS --type merge -p '{"spec":{"runStrategy":"Always"}}'
```
