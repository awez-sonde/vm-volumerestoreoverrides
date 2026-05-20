# OpenShift GitOps — volumeRestoreOverrides demo

This folder registers **Argo CD Applications** (OpenShift GitOps) that deploy the same manifests at the repo root (`fedora-demo-vm.yaml`, `snapshot.yaml`, `restore-with-overrides.yaml`) on your cluster.

Applications are split by demo phase so you can sync them in order, matching the manual procedure in the [root README](../README.md).

## Layout

| Path | Purpose |
|------|---------|
| `appproject.yaml` | Argo CD `AppProject` scoped to `vm-demo` |
| `applications/01-fedora-vm.yaml` | Namespace + VM (auto-sync) |
| `applications/02-fedora-snapshot.yaml` | `VirtualMachineSnapshot` (sync when VM is ready) |
| `applications/03-fedora-restore.yaml` | `VirtualMachineRestore` with `volumeRestoreOverrides` (sync after halt) |
| `bootstrap/root-application.yaml` | App-of-apps: installs project + child applications |

## Prerequisites

- OpenShift cluster with **OpenShift GitOps** (Argo CD) installed
- OpenShift Virtualization and a CSI class that supports snapshots (same as root README)
- `cluster-admin` or permission to create `Application` / `AppProject` in `openshift-gitops`
- Git access from the cluster to this repository (public URL, or configure repo credentials in Argo CD)

## 1. Register the demo (one-time)

Point Argo CD at this repo. If you use a fork or another branch, edit `repoURL` / `targetRevision` in the YAML files under `gitops/` first.

```bash
oc apply -f gitops/bootstrap/root-application.yaml
```

That creates:

- AppProject `vm-volume-restore-demo`
- Applications `fedora-demo-vm`, `fedora-demo-snapshot`, `fedora-demo-restore`

Confirm in the Argo CD UI (**OpenShift GitOps → GitOps → Cluster Argo CD → Open Argo CD UI**) or:

```bash
oc get applications -n openshift-gitops -l app.kubernetes.io/part-of=volume-restore-overrides-demo
```

## 2. Demo flow via GitOps

| Step | Action | GitOps |
|------|--------|--------|
| 1 | Deploy VM | `fedora-demo-vm` syncs automatically (or **Sync** in UI) |
| 2 | Wait for VM Ready | `oc wait vm/fedora-demo -n vm-demo --for=condition=Ready --timeout=300s` |
| 3 | Verify original page | See root README |
| 4 | Take snapshot | **Sync** `fedora-demo-snapshot` (not auto-sync) |
| 5 | Wait snapshot ready | `oc wait virtualmachinesnapshot/fedora-demo-snap -n vm-demo --for=jsonpath='{.status.readyToUse}'=true --timeout=120s` |
| 6 | Modify page / verify drift | Manual steps in root README |
| 7 | Halt VM | `oc patch vm fedora-demo -n vm-demo --type merge -p '{"spec":{"runStrategy":"Halted"}}'` |
| 8 | Restore with overrides | **Sync** `fedora-demo-restore` |
| 9 | Start VM & verify | Root README steps 9–10 |

CLI sync examples:

```bash
argocd app sync fedora-demo-snapshot -n openshift-gitops
argocd app sync fedora-demo-restore -n openshift-gitops
```

Or from the OpenShift console: **Sync** on the corresponding Application.

**Important:** Do not sync `fedora-demo-restore` until the VM is halted and the snapshot is `readyToUse`. The restore Application is intentionally **not** auto-synced.

## 3. Repo URL / branch overrides

If this code lives in a different remote or branch, update `repoURL` and `targetRevision` in:

- `gitops/bootstrap/root-application.yaml`
- `gitops/applications/*.yaml`
- `gitops/appproject.yaml` (`sourceRepos` allow-list)

## 4. Teardown

```bash
oc delete application volume-restore-overrides-demo fedora-demo-vm fedora-demo-snapshot fedora-demo-restore -n openshift-gitops --ignore-not-found
oc delete appproject vm-volume-restore-demo -n openshift-gitops --ignore-not-found
oc delete -f restore-with-overrides.yaml -f snapshot.yaml -f fedora-demo-vm.yaml --ignore-not-found
```

## Design notes

- **Same files as `oc apply`:** Child apps use `directory.include` so Argo deploys only the matching root manifest; nothing is duplicated under `gitops/`.
- **VM runStrategy:** `fedora-demo-vm` ignores drift on `spec.runStrategy` so halting the VM for restore does not show OutOfSync for that field.
- **Auto-sync:** Only the VM app auto-syncs; snapshot and restore are manual to preserve the demo sequence.
