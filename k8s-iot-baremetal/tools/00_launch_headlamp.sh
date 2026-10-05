#!/bin/bash
# Project: k8s-iot-baremetal
# Description: Install Headlamp (if missing) and launch it against the cluster.
#              Headlamp is a Kubernetes UI desktop app — runs locally on your
#              laptop and connects to the cluster via kubeconfig.
# Author: Mauro A. Pereira

set -e

CONTEXT="k8s-iot-baremetal"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +'%H:%M:%S')] $1${NC}"; }
ok()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }

# ── 1. Install Headlamp if missing ───────────────────────────────────────────
if ! command -v headlamp &> /dev/null; then
    log "Headlamp not found. Fetching latest release..."

    LATEST_URL=$(curl -Ls https://api.github.com/repos/kubernetes-sigs/headlamp/releases/latest \
        | grep "browser_download_url.*amd64\.deb" \
        | cut -d'"' -f4)

    if [ -z "$LATEST_URL" ]; then
        echo "ERROR: Could not fetch Headlamp download URL. Check your internet connection."
        exit 1
    fi

    DEB_FILE="/tmp/headlamp.deb"
    log "Downloading: ${LATEST_URL}"
    curl -L -o "$DEB_FILE" "$LATEST_URL"

    log "Installing..."
    sudo dpkg -i "$DEB_FILE"
    rm -f "$DEB_FILE"

    ok "Headlamp installed."
else
    ok "Headlamp already installed: $(headlamp --version 2>/dev/null || echo 'version unknown')"
fi

# ── 2. Verify cluster context ────────────────────────────────────────────────
log "Verifying kubectl context '${CONTEXT}'..."
if ! kubectl config get-contexts "$CONTEXT" &> /dev/null; then
    echo "ERROR: kubectl context '${CONTEXT}' not found. Run 00_deploy_cluster.sh first."
    exit 1
fi
kubectl config use-context "$CONTEXT" > /dev/null
ok "Context set to '${CONTEXT}'."

# ── 3. Install metrics-server if missing ────────────────────────────────────
log "Checking metrics-server..."
if ! kubectl get deployment metrics-server -n kube-system &> /dev/null; then
    log "metrics-server not found. Installing..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    log "Patching metrics-server for bare metal (--kubelet-insecure-tls)..."
    kubectl patch deployment metrics-server -n kube-system \
        --type=json \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    log "Waiting for metrics-server to be ready..."
    kubectl wait --for=condition=available deployment/metrics-server -n kube-system --timeout=60s
    ok "metrics-server installed."
else
    ok "metrics-server already installed."
fi

# ── 4. Launch Headlamp ───────────────────────────────────────────────────────
log "Launching Headlamp..."
headlamp > /dev/null 2>&1 &
ok "Headlamp launched. Opening in browser..."
