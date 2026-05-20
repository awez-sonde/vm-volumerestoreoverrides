# OpenShift Virtualization - Snapshot & Restore with volumeRestoreOverrides

This demo shows how to use `volumeRestoreOverrides` in OpenShift Virtualization
to restore a VM from a snapshot.

## Prerequisites

- OpenShift cluster with OpenShift Virtualization installed 
- A CSI storage class that supports VolumeSnapshots (e.g. Ceph RBD)
- A VolumeSnapshotClass configured

## Files

| File | Description |
|------|-------------|
| `fedora-demo-vm.yaml` | VM with DataVolume, cloud-init (httpd + demo page) |
| `snapshot.yaml` | VirtualMachineSnapshot definition |
| `restore-with-overrides.yaml` | VirtualMachineRestore with `volumeRestoreOverrides` |
| `gitops/` | OpenShift GitOps (Argo CD) Applications for the same manifests — see [gitops/README.md](gitops/README.md) |

## Step-by-Step Test Procedure

### 1. Deploy the VM

```bash
oc apply -f fedora-demo-vm.yaml
```

Wait for the DataVolume to import and the VM to start:

```bash
oc wait vm/fedora-demo -n vm-demo --for=condition=Ready --timeout=300s
```

### 2. Verify the original page

```bash
VM_IP=$(oc get vmi fedora-demo -n vm-demo -o jsonpath='{.status.interfaces[0].ipAddress}')
oc run curl-test --rm -i --restart=Never -n vm-demo --image=curlimages/curl -- curl -s http://$VM_IP
```

Expected output:
```
<html><body><h1>Original Page - Snapshot Demo</h1><p>This is the ORIGINAL page before snapshot restore.</p></body></html>
```

### 3. Take a snapshot

```bash
oc apply -f snapshot.yaml
```

Wait for the snapshot to be ready:

```bash
oc wait virtualmachinesnapshot/fedora-demo-snap -n vm-demo \
  --for=jsonpath='{.status.readyToUse}'=true --timeout=120s
```

### 4. Modify the page (simulate drift)

```bash
oc run ssh-modify --rm -i --restart=Never -n vm-demo \
  --image=quay.io/fedora/fedora:40 -- /bin/bash -c \
  "dnf install -y -q sshpass openssh-clients 2>/dev/null && \
   sshpass -p 'redhat123' ssh -o StrictHostKeyChecking=no fedora@$VM_IP \
   \"echo '<html><body><h1>MODIFIED Page</h1><p>Content changed AFTER snapshot.</p></body></html>' | sudo tee /var/www/html/index.html\""
```

### 5. Verify the page changed

```bash
oc run curl-test2 --rm -i --restart=Never -n vm-demo --image=curlimages/curl -- curl -s http://$VM_IP
```

Expected output: `<h1>MODIFIED Page</h1>`

### 6. Stop the VM

```bash
oc patch vm fedora-demo -n vm-demo --type merge -p '{"spec":{"runStrategy":"Halted"}}'
```

Wait for the VMI to be deleted:

```bash
oc wait vmi/fedora-demo -n vm-demo --for=delete --timeout=300s
```

### 7. Restore from snapshot with volumeRestoreOverrides

```bash
oc apply -f restore-with-overrides.yaml
```

Wait for restore to complete:

```bash
oc wait virtualmachinerestore/fedora-demo-restore -n vm-demo \
  --for=jsonpath='{.status.complete}'=true --timeout=120s
```

### 8. Verify volumeRestoreOverrides applied

```bash
oc get pvc fedora-demo-disk-from-snap -n vm-demo \
  -o jsonpath='{.metadata.labels.restore-test}'
# Output: true

oc get pvc fedora-demo-disk-from-snap -n vm-demo \
  -o jsonpath='{.metadata.annotations.description}'
# Output: Restored from snapshot fedora-demo-snap using volumeRestoreOverrides
```

### 9. Start the VM

```bash
oc patch vm fedora-demo -n vm-demo --type merge -p '{"spec":{"runStrategy":"Always"}}'
```

### 10. Verify original page is restored

```bash
VM_IP=$(oc get vmi fedora-demo -n vm-demo -o jsonpath='{.status.interfaces[0].ipAddress}')
oc run curl-final --rm -i --restart=Never -n vm-demo --image=curlimages/curl -- curl -s http://$VM_IP
```

Expected output:
```
<html><body><h1>Original Page - Snapshot Demo</h1><p>This is the ORIGINAL page before snapshot restore.</p></body></html>
```

## volumeRestoreOverrides Fields

| Field | Description |
|-------|-------------|
| `volumeName` | Name of the volume in the VM spec to override |
| `restoreName` | Custom name for the restored PVC |
| `labels` | Additional labels to add to the restored PVC |
| `annotations` | Additional annotations to add to the restored PVC |



