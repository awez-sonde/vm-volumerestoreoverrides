# OpenShift GitOps — volumeRestoreOverrides demo

This folder deploys the **same manifests** at the repo root (`fedora-demo-vm.yaml`, `snapshot.yaml`, `restore-with-overrides.yaml`) into a **separate namespace** from the manual `oc apply` demo.

| Manual demo (`oc apply`) | GitOps demo (this folder) |
|--------------------------|---------------------------|
| Namespace `vm-demo` | Namespace `vm-volume-restore-demo` |
| Root YAML as-is | Kustomize overlays rewrite namespace only |

Both can run on the same cluster without conflicting.

## How the demo flow works

**You already have three separate Applications** (VM, snapshot, restore). They do **not** all run in one sync.

| Step | What you do | Argo CD Application |
|------|-------------|---------------------|
| 1 | Create VM | `fedora-demo-vm` — **Sync** when ready |
| 2 | Create snapshot | `fedora-demo-snapshot` — **Sync** when VM is Ready |
| 3 | Add drift to the VM | **Manual** (`oc` / SSH) — no Application |
| 4 | Restore VM | `fedora-demo-restore` — **Sync** after halt + snapshot ready |

A fourth app, `volume-restore-overrides-demo`, is only the **installer** (registers the three apps). See **[DEMO-FLOW.md](DEMO-FLOW.md)** for a diagram and commands.

## Layout

| Path | Purpose |
|------|---------|
| `overlays/vm-volume-restore-demo/vm/` | Copy of `fedora-demo-vm.yaml` + Kustomize namespace rewrite |
| `overlays/vm-volume-restore-demo/snapshot/` | Copy of `snapshot.yaml` + namespace rewrite |
| `overlays/vm-volume-restore-demo/restore/` | Copy of `restore-with-overrides.yaml` + namespace rewrite |
| `scripts/sync-manifests.sh` | Re-copy root manifests into overlays after you edit them |
| `appproject.yaml` | Argo CD `AppProject` scoped to `vm-volume-restore-demo` |
| `applications/*.yaml` | Phase Applications (VM / snapshot / restore) |
| `bootstrap/root-application.yaml` | App-of-apps bootstrap |

## Troubleshooting

### Empty Argo CD UI (no applications listed)

OpenShift GitOps RBAC only grants the **admin** role to OpenShift `cluster-admins` by default. Log in with the local Argo CD user **`admin`** (not only OpenShift SSO), or add your user/group to the Argo CD policy:

```bash
oc patch argocd openshift-gitops -n openshift-gitops --type merge -p \
  '{"spec":{"rbac":{"policy":"g, system:cluster-admins, role:admin\ng, cluster-admins, role:admin\ng, admin, role:admin\n"}}}'
```

Password:

```bash
oc get secret openshift-gitops-cluster -n openshift-gitops \
  -o jsonpath='{.data.admin\.password}' | base64 -d; echo
```

Confirm CRs exist (CLI): `oc get applications.argoproj.io -n openshift-gitops`

### Child apps `Unknown` / `InvalidSpecError` on destination

The AppProject must allow the Application destination namespace. Child apps must set:

```yaml
destination:
  namespace: vm-volume-restore-demo
```

## Prerequisites

- OpenShift cluster with **OpenShift GitOps** and **OpenShift Virtualization**
- CSI storage class supporting VolumeSnapshots (same as root README)
- Git access from the cluster to this repository

## 1. Register the demo (one-time)

```bash
oc apply -f gitops/bootstrap/root-application.yaml
```

```bash
oc get applications -n openshift-gitops -l app.kubernetes.io/part-of=volume-restore-overrides-demo
```

## 2. Demo flow (namespace `vm-volume-restore-demo`)

Follow **[DEMO-FLOW.md](DEMO-FLOW.md)**. Short version:

1. **Sync** `fedora-demo-vm` → wait for VM Ready  
2. **Sync** `fedora-demo-snapshot` → wait for snapshot `readyToUse`  
3. **Manual drift** → change web page (root README, use `-n vm-volume-restore-demo`)  
4. Halt VM → **Sync** `fedora-demo-restore` → start VM and verify page

None of the three workload apps auto-sync; you choose when each step runs in the Argo CD UI.

## 3. Change the target namespace

Edit namespace in each overlay `kustomization.yaml` under `gitops/overlays/vm-volume-restore-demo/`, then update `gitops/appproject.yaml` destinations and `applications/01-fedora-vm.yaml` `ignoreDifferences` namespace.

## 4. Repo URL / branch

Update `repoURL` and `targetRevision` in `bootstrap/`, `applications/`, and `appproject.yaml` if not using the default GitHub remote.

## 5. Teardown (GitOps namespace only)

```bash
oc delete application volume-restore-overrides-demo fedora-demo-vm fedora-demo-snapshot fedora-demo-restore -n openshift-gitops --ignore-not-found
oc delete appproject vm-volume-restore-demo -n openshift-gitops --ignore-not-found
oc delete namespace vm-volume-restore-demo --ignore-not-found
```

The manual demo in `vm-demo` is untouched.

## Design notes

- **Same VM/snapshot/restore specs:** Each overlay folder holds a copy of the root YAML (Argo Kustomize cannot read files outside the overlay path). After editing root manifests, run `gitops/scripts/sync-manifests.sh`.
- **Namespace isolation:** GitOps workload lives in `vm-volume-restore-demo`; original files still document `vm-demo` for `oc apply`.
- **Manual sync per step:** VM, snapshot, and restore each have their own Application; sync only when that step should run.
- **VM runStrategy:** `fedora-demo-vm` ignores `spec.runStrategy` drift after you halt the VM for restore.
