#!/usr/bin/env bash
# Keep overlay copies aligned with the canonical root manifests (oc apply demo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OVERLAY="${ROOT}/overlays/vm-volume-restore-demo"

cp "${ROOT}/../fedora-demo-vm.yaml" "${OVERLAY}/vm/fedora-demo-vm.yaml"
cp "${ROOT}/../snapshot.yaml" "${OVERLAY}/snapshot/snapshot.yaml"
cp "${ROOT}/../restore-with-overrides.yaml" "${OVERLAY}/restore/restore-with-overrides.yaml"

echo "Synced root manifests into ${OVERLAY}"
