#!/usr/bin/env bash
# End-to-end: file on disk -> snapshot -> delete VM -> new VM -> restore -> file still there
set -euo pipefail

NS="${NS:-vm-volume-restore-demo}"
GITOPS_NS="${GITOPS_NS:-openshift-gitops}"
TESTFILE="/home/fedora/restore-test-file.txt"
CONTENT="CREATED_BEFORE_SNAPSHOT_$(date -u +%Y%m%dT%H%M%SZ)"

log() { echo ""; echo "=== $* ==="; }

# Wait until a namespaced resource exists (Argo sync is async)
wait_for_object() {
  local kind="$1" name="$2" timeout="${3:-300}"
  local elapsed=0
  echo "Waiting for ${kind}/${name} to exist..."
  until oc get "$kind" "$name" -n "$NS" &>/dev/null; do
    sleep 3
    elapsed=$((elapsed + 3))
    if [[ $elapsed -ge $timeout ]]; then
      echo "ERROR: ${kind}/${name} not created within ${timeout}s"
      echo "Check: oc get application -n ${GITOPS_NS}; oc describe application fedora-demo-vm -n ${GITOPS_NS}"
      exit 1
    fi
  done
}

sync_app() {
  local app="$1"
  oc patch application "$app" -n "$GITOPS_NS" \
    --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
  echo "Triggered sync for ${app}; waiting for Synced..."
  local elapsed=0
  while true; do
    local status
    status=$(oc get application "$app" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
    if [[ "$status" == "Synced" ]]; then
      echo "${app} is Synced"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
    if [[ $elapsed -ge 300 ]]; then
      echo "WARN: ${app} not Synced after 300s (status=${status}); continuing..."
      return 0
    fi
  done
}

wait_vm_ready() {
  wait_for_object vm fedora-demo 300
  oc wait vm/fedora-demo -n "$NS" --for=condition=Ready --timeout=600s
  wait_for_object vmi fedora-demo 300
  oc wait vmi/fedora-demo -n "$NS" --for=condition=Ready --timeout=300s
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
wait_vm_ready

log "STEP 1b: Create file inside VM"
ssh_vm "echo '${CONTENT}' | tee ${TESTFILE} && cat ${TESTFILE}"

log "STEP 2: Snapshot (sync fedora-demo-snapshot)"
sync_app fedora-demo-snapshot
wait_for_object virtualmachinesnapshot fedora-demo-snap 120
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
wait_vm_ready

log "STEP 4b: Halt VM before restore"
oc patch vm fedora-demo -n "$NS" --type merge -p '{"spec":{"runStrategy":"Halted"}}'
oc wait vmi/fedora-demo -n "$NS" --for=delete --timeout=120s

log "STEP 4c: Restore (sync fedora-demo-restore)"
oc delete virtualmachinerestore fedora-demo-restore -n "$NS" --ignore-not-found --wait=true
sync_app fedora-demo-restore
wait_for_object virtualmachinerestore fedora-demo-restore 120
oc wait virtualmachinerestore/fedora-demo-restore -n "$NS" \
  --for=jsonpath='{.status.complete}'=true --timeout=300s
oc get pvc fedora-demo-disk-from-snap -n "$NS"

log "STEP 5: Start VM and verify file"
oc patch vm fedora-demo -n "$NS" --type merge -p '{"spec":{"runStrategy":"Always"}}'
wait_vm_ready
sleep 25
ssh_vm "cat ${TESTFILE}"

log "SUCCESS: file restored from snapshot"
