# OpenShift GitOps — volumeRestoreOverrides demo

This folder deploys the **same manifests** at the repo root (`fedora-demo-vm.yaml`, `snapshot.yaml`, `restore-with-overrides.yaml`) into a **separate namespace** from the manual `oc apply` demo.

| Manual demo (`oc apply`) | GitOps demo (this folder) |
|--------------------------|---------------------------|
| Namespace `vm-demo` | Namespace `vm-volume-restore-demo` |
| Root YAML as-is | Kustomize overlays rewrite namespace only |

Both can run on the same cluster without conflicting.

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

| Step | Action | GitOps |
|------|--------|--------|
| 1 | Deploy VM | `fedora-demo-vm` auto-syncs (creates namespace + VM) |
| 2 | Wait for VM Ready | `oc wait vm/fedora-demo -n vm-volume-restore-demo --for=condition=Ready --timeout=300s` |
| 3 | Verify original page | Use `vm-volume-restore-demo` in curl/ssh steps from [root README](../README.md) |
| 4 | Take snapshot | **Sync** `fedora-demo-snapshot` |
| 5 | Wait snapshot ready | `oc wait virtualmachinesnapshot/fedora-demo-snap -n vm-volume-restore-demo --for=jsonpath='{.status.readyToUse}'=true --timeout=120s` |
| 6 | Modify page / verify drift | Same as root README, replace `-n vm-demo` with `-n vm-volume-restore-demo` |
| 7 | Halt VM | `oc patch vm fedora-demo -n vm-volume-restore-demo --type merge -p '{"spec":{"runStrategy":"Halted"}}'` |
| 8 | Restore with overrides | **Sync** `fedora-demo-restore` |
| 9 | Start VM & verify | `oc patch vm fedora-demo -n vm-volume-restore-demo --type merge -p '{"spec":{"runStrategy":"Always"}}'` then curl test |

```bash
argocd app sync fedora-demo-snapshot -n openshift-gitops
argocd app sync fedora-demo-restore -n openshift-gitops
```

Do not sync `fedora-demo-restore` until the VM is halted and the snapshot is `readyToUse`.

## 3. Change the target namespace

Edit `gitops/overlays/vm-volume-restore-demo/component/kustomization.yaml`:

- `namespace:` field
- Namespace patch `value` (must match)

Update `gitops/appproject.yaml` destinations and `ignoreDifferences` namespace in `applications/01-fedora-vm.yaml`.

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
- **VM runStrategy:** `fedora-demo-vm` ignores `spec.runStrategy` drift after you halt the VM for restore.
