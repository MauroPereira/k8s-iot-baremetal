#!/bin/bash
# Project: k8s-iot-baremetal
# Description: Wrapper to bootstrap sudo on nodes, run Ansible deployment,
#              and configure local kubectl access.
# Author: Mauro A. Pereira

set -e

# Determine the script's directory to ensure paths are always relative to it
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# Logging: mirror all output to a log file
LOG_FILE="${SCRIPT_DIR}/deploy_cluster.log"
exec > >(tee "$LOG_FILE") 2>&1

# Configuration
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory.ini"
PLAYBOOK="${ANSIBLE_DIR}/playbook.yml"
CONTEXT_NAME="k8s-iot-baremetal"
KUBECONFIG_TMP="/tmp/${CONTEXT_NAME}.yml"

# Read SSH user and node IPs from inventory (single source of truth)
SSH_USER=$(grep 'ansible_user=' "$INVENTORY" | head -1 | cut -d'=' -f2)
mapfile -t NODES < <(grep 'ansible_host=' "$INVENTORY" | awk -F'ansible_host=' '{print $2}')

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $1${NC}"
}

# Handle arguments
SKIP_BOOTSTRAP=false
SKIP_ANSIBLE=false
SKIP_KUBECONFIG=false
RESET_CLUSTER=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--skip-bootstrap)  SKIP_BOOTSTRAP=true ;;
        -a|--skip-ansible)    SKIP_ANSIBLE=true; SKIP_BOOTSTRAP=true ;;
        -k|--skip-kubeconfig) SKIP_KUBECONFIG=true ;;
        -r|--reset)           RESET_CLUSTER=true ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# 0. Reset cluster on all nodes (if requested)
if [ "$RESET_CLUSTER" = true ]; then
    log "Resetting existing cluster on all nodes..."
    for ip in "${NODES[@]}"; do
        log "Resetting ${ip}..."
        ssh "${SSH_USER}@${ip}" "sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d /etc/kubernetes /var/lib/kubelet && sudo ip link delete cni0 2>/dev/null; sudo ip link delete flannel.1 2>/dev/null; true"
    done
    log "Reset complete."
fi

# 1. Bootstrap sudo on all nodes
if [ "$SKIP_BOOTSTRAP" = false ]; then
    log "Starting sudo bootstrap process on all nodes..."
    for ip in "${NODES[@]}"; do
        log "Ensuring sudo and passwordless access for ${SSH_USER} on ${ip}..."
        # 1. Install sudo
        # 2. Add user to sudo group
        # 3. Configure NOPASSWD
        ssh -t "${SSH_USER}@${ip}" "su -c 'apt update && apt install sudo -y && /usr/sbin/usermod -aG sudo ${SSH_USER} && echo \"${SSH_USER} ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/${SSH_USER}'"
    done
else
    log "Skipping sudo bootstrap as requested."
fi

# 2. Run Ansible Playbook
if [ "$SKIP_ANSIBLE" = false ]; then
    log "Sudo bootstrap complete. Starting Ansible deployment..."
    ansible-playbook -i "$INVENTORY" "$PLAYBOOK"
    log "Deployment process finished!"
else
    log "Skipping Ansible deployment as requested."
fi

# 3. Configure local kubectl access
if [ "$SKIP_KUBECONFIG" = false ]; then
    log "Configuring local kubectl access..."

    log "Copying kubeconfig from control plane (${NODES[0]})..."
    scp "${SSH_USER}@${NODES[0]}:~/.kube/config" "$KUBECONFIG_TMP"

    log "Renaming entries to avoid collisions with existing configs..."
    sed -i \
        -e "s/name: kubernetes\$/name: ${CONTEXT_NAME}/" \
        -e "s/cluster: kubernetes\$/cluster: ${CONTEXT_NAME}/" \
        -e "s/name: kubernetes-admin@kubernetes/name: ${CONTEXT_NAME}/" \
        -e "s/current-context: kubernetes-admin@kubernetes/current-context: ${CONTEXT_NAME}/" \
        -e "s/user: kubernetes-admin\$/user: ${CONTEXT_NAME}-admin/" \
        -e "s/name: kubernetes-admin\$/name: ${CONTEXT_NAME}-admin/" \
        "$KUBECONFIG_TMP"

    if [ -f "$HOME/.kube/config" ]; then
        log "Removing stale kubeconfig entries for ${CONTEXT_NAME}..."
        kubectl config delete-cluster "${CONTEXT_NAME}" 2>/dev/null || true
        kubectl config delete-user "${CONTEXT_NAME}-admin" 2>/dev/null || true
        kubectl config delete-context "${CONTEXT_NAME}" 2>/dev/null || true

        log "Merging kubeconfigs..."
        KUBECONFIG_MERGED="/tmp/${CONTEXT_NAME}-merged.yml"
        KUBECONFIG="$HOME/.kube/config:$KUBECONFIG_TMP" kubectl config view --flatten > "$KUBECONFIG_MERGED"
        KUBECONFIG="$KUBECONFIG_MERGED" kubectl config set-context "${CONTEXT_NAME}" --user="${CONTEXT_NAME}-admin"
        KUBECONFIG="$KUBECONFIG_MERGED" kubectl config use-context "${CONTEXT_NAME}"

        if ! diff -q "$HOME/.kube/config" "$KUBECONFIG_MERGED" > /dev/null 2>&1; then
            log "Kubeconfig changed: backing up current to ~/.kube/config.bak and installing new config..."
            mv "$HOME/.kube/config" "$HOME/.kube/config.bak"
            mv "$KUBECONFIG_MERGED" "$HOME/.kube/config"
        else
            log "Kubeconfig unchanged. Nothing to do."
            rm -f "$KUBECONFIG_MERGED"
        fi
    else
        log "No existing kubeconfig found. Installing directly..."
        mkdir -p "$HOME/.kube"
        cp "$KUBECONFIG_TMP" "$HOME/.kube/config"
    fi

    log "Verifying cluster access..."
    echo -e "\n${CYAN}$(kubectl config get-contexts)${NC}\n"
    kubectl --context="${CONTEXT_NAME}" get nodes
    log "Done. Use --context=${CONTEXT_NAME} to interact with this cluster."
else
    log "Skipping local kubeconfig setup as requested."
fi
