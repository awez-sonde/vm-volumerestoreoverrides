#!/usr/bin/env bash
# End-to-end: file on disk -> snapshot -> delete VM -> new VM -> restore -> file still there
set -euo pipefail

NS="${NS:-vm-volume-restore-demo}"
GITOPS_NS="${GITOPS_NS:-openshift-gitops}"
TESTFILE="/home/fedora/restore-test-file.txt"
CONTENT="CREATED_BEFORE_SNAPSHOT_$(date -u +%Y%m%dT%H%M%SZ)"

log() { echo ""; echo "=== $* ==="; }

sync_app() {
  oc patch application "$1" -n "$GITOPS_NS" \
    --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
}

ssh_vm() {
  local cmd="$1"
  local ip
  ip=$(oc get vmi fedora-demo -n "$NS" -o jsonpath='{.status.interfaces[0].ipAddress}')
  oc run "ssh-$(date +%s)" --rm -i --restart=Never -n "$NS" \
    --image=quay.io/fedora/fedora:40 -- /bin/bash -c \
    "dnf install -y -q sshpass openssh-clients 2>/dev/null && \
     sshpass -p 'redhat123' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 fedora@${ip} '${cmd}'"
}

# Stop Argo from recreating the VM while it is deleted (common failure mode)
log "Disable Argo selfHeal on fedora-demo-vm"
oc patch application fedora-demo-vm -n "$GITOPS_NS" --type=json \
  -p='[{"op": "remove", "path": "/spec/syncPolicy/automated"}]' 2>/dev/null || true

log "STEP 0: Clean slate (optional — comment out if starting fresh)"
oc delete virtualmachinerestore fedora-demo-restore -n "$NS" --ignore-not-found --wait=true
oc patch vm fedora-demo -n "$NS" --type merge -p '{"spec":{"runStrategy":"Halted"}}' 2>/dev/null || true
oc wait vmi/fedora-demo -n "$NS" --for=delete --timeout=120s 2>/dev/null || true
oc delete vm fedora-demo -n "$NS" --ignore-not-found --wait=true
oc delete virtualmachinesnapshot fedora-demo-snap -n "$NS" --ignore-not-found --wait=true
oc delete dv,pvc -n "$NS" --all --ignore-not-found --wait=true

log "STEP 1: Create VM (sync fedora-demo-vm)"
sync_app fedora-demo-vm
oc wait vm/fedora-demo -n "$NS" --for=condition=Ready --timeout=600s
oc wait vmi/fedora-demo -n "$NS" --for=condition=Ready --timeout=300s

log "STEP 1b: Create file inside VM"
ssh_vm "echo '${CONTENT}' | tee ${TESTFILE} && cat ${TESTFILE}"

log "STEP 2: Snapshot (sync fedora-demo-snapshot)"
sync_app fedora-demo-snapshot
oc wait virtualmachinesnapshot/fedora-demo-snap -n "$NS" \
  --for=jsonpath='{.status.readyToUse}'=true --timeout=180s

log "STEP 3: Delete VM only (keep snapshot)"
oc patch vm fedora-demo -n "$NS" --type merge -p '{"spec":{"runStrategy":"Halted"}}'
oc wait vmi/fedora-demo -n "$NS" --for=delete --timeout=120s
oc delete vm fedora-demo -n "$NS" --wait=true
oc delete dv fedora-demo-rootdisk -n "$NS" --ignore-not-found --wait=true
oc delete pvc fedora-demo-rootdisk -n "$NS" --ignore-not-found --wait=true
oc get virtualmachinesnapshot fedora-demo-snap -n "$NS"

log "STEP 4a: Recreate VM (sync fedora-demo-vm)"
sync_app fedora-demo-vm
oc wait vm/fedora-demo -n "$NS" --for=condition=Ready --timeout=600s

log "STEP 4b: Halt VM before restore"
oc patch vm fedora-demo -n "$NS" --type merge -p '{"spec":{"runStrategy":"Halted"}}'
oc wait vmi/fedora-demo -n "$NS" --for=delete --timeout=120s

log "STEP 4c: Restore (sync fedora-demo-restore)"
oc delete virtualmachinerestore fedora-demo-restore -n "$NS" --ignore-not-found --wait=true
sync_app fedora-demo-restore
oc wait virtualmachinerestore/fedora-demo-restore -n "$NS" \
  --for=jsonpath='{.status.complete}'=true --timeout=300s
oc get pvc fedora-demo-disk-from-snap -n "$NS"

log "STEP 5: Start VM and verify file"
oc patch vm fedora-demo -n "$NS" --type merge -p '{"spec":{"runStrategy":"Always"}}'
oc wait vm/fedora-demo -n "$NS" --for=condition=Ready --timeout=600s
oc wait vmi/fedora-demo -n "$NS" --for=condition=Ready --timeout=300s
sleep 25
ssh_vm "cat ${TESTFILE}"

log "SUCCESS: file restored from snapshot"
