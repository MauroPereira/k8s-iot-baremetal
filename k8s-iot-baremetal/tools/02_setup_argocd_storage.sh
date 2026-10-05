#!/bin/bash
# Project: k8s-iot-baremetal
# Description: Create ArgoCD Application for cluster storage (local-path-provisioner).
#              Watches k8s-iot-baremetal/k8s/storage/ on the dev branch.
#              Requires: 01_setup_argocd_iot_pipeline.sh already executed.
# Author: Mauro A. Pereira

set -e

REPO_URL="https://github.com/MauroPereira/k8s-iot-baremetal.git"
REPO_BRANCH="dev"
REPO_PATH="k8s-iot-baremetal/k8s/storage"
APP_NAME="cluster-storage"
ARGOCD_NS="argocd"
STORAGE_NS="local-path-storage"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[$(date +'%H:%M:%S')] $1${NC}"; }
ok()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }

log "Note: local-path-provisioner manifest was downloaded from:"
log "  https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"
log "  and committed to k8s-iot-baremetal/k8s/storage/local-path-provisioner.yml"
echo ""
log "Creating ArgoCD Application '${APP_NAME}'..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${ARGOCD_NS}
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REPO_BRANCH}
    path: ${REPO_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${STORAGE_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
ok "Application '${APP_NAME}' created."
ok "Watching ${REPO_BRANCH}:${REPO_PATH} → namespace ${STORAGE_NS}"
