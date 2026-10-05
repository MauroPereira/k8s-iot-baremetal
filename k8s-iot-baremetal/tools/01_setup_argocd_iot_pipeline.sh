#!/bin/bash
# Project: k8s-iot-baremetal
# Description: Install ArgoCD and configure it to watch k8s-iot-baremetal/k8s/
#              on the dev branch. Any manifest committed to that path is
#              automatically deployed to the cluster (GitOps).
# Author: Mauro A. Pereira

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_URL="https://github.com/MauroPereira/k8s-iot-baremetal.git"
REPO_BRANCH="dev"
REPO_PATH="k8s-iot-baremetal/k8s"
APP_NAME="iot-pipeline"
ARGOCD_NS="argocd"
IOT_NS="iot"

# ── Sync retry policy ────────────────────────────────────────────────────────
# How many times ArgoCD retries a failed sync before giving up and alerting.
RETRY_LIMIT=3
# Wait time before the first retry.
RETRY_DURATION="12s"
# Each retry waits twice as long as the previous one (e.g. for 12s → 24s → 48s).
RETRY_FACTOR=2
# Maximum wait per individual retry — caps the backoff so no single retry waits longer than this value.
RETRY_MAX_DURATION="30s"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[$(date +'%H:%M:%S')] $1${NC}"; }
ok()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }

# ── 1. Install ArgoCD ────────────────────────────────────────────────────────
if kubectl get namespace "$ARGOCD_NS" &> /dev/null; then
    ok "ArgoCD namespace already exists, skipping install."
else
    log "Creating ArgoCD namespace..."
    kubectl create namespace "$ARGOCD_NS"

    log "Installing ArgoCD..."
    kubectl apply -n "$ARGOCD_NS" --server-side -f \
        https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    log "Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=available deployment/argocd-server \
        -n "$ARGOCD_NS" --timeout=120s
    ok "ArgoCD installed."
fi

# ── 2. Expose ArgoCD UI via NodePort ────────────────────────────────────────
if ! kubectl get svc argocd-server-nodeport -n "$ARGOCD_NS" &> /dev/null; then
    log "Exposing ArgoCD UI via NodePort..."
    kubectl patch svc argocd-server -n "$ARGOCD_NS" \
        -p '{"spec": {"type": "NodePort"}}'
    ok "ArgoCD UI exposed."
fi

NODEPORT=$(kubectl get svc argocd-server -n "$ARGOCD_NS" \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# ── 3. Create ArgoCD Application ────────────────────────────────────────────
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
    directory:
      recurse: true
      exclude: storage/**
  destination:
    server: https://kubernetes.default.svc
    namespace: ${IOT_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: ${RETRY_LIMIT}
      backoff:
        duration: ${RETRY_DURATION}
        maxDuration: ${RETRY_MAX_DURATION}
        factor: ${RETRY_FACTOR}
EOF
ok "Application '${APP_NAME}' created."

# ── 4. Print access info ─────────────────────────────────────────────────────
ADMIN_PASS=$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

echo ""
ok "======= ArgoCD ready ======="
ok "UI:       https://${NODE_IP}:${NODEPORT}"
ok "User:     admin"
ok "Password: ${ADMIN_PASS}"
ok "App:      ${APP_NAME} → watching ${REPO_BRANCH}:${REPO_PATH}"
echo ""
log "Note: accept the self-signed certificate warning in the browser."
log "Change the admin password after first login."
