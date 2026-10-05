#!/bin/bash
# Project: k8s-iot-baremetal
# Description: Deploy IoT pipeline (Mosquitto, InfluxDB, Telegraf, Grafana) on the cluster.
# Author: Mauro A. Pereira

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
CONTEXT="k8s-iot-baremetal"

GREEN='\033[0;32m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $1${NC}"; }

log "Creating iot namespace..."
kubectl --context="${CONTEXT}" apply -f "${K8S_DIR}/namespace.yml"

for component in mosquitto influxdb telegraf grafana; do
    dir="${K8S_DIR}/${component}"
    [ -d "$dir" ] || continue
    log "Deploying ${component}..."
    kubectl --context="${CONTEXT}" apply -f "${dir}/"
done

log "Waiting for deployments to be ready..."
kubectl --context="${CONTEXT}" -n iot wait --for=condition=available --timeout=120s deployment --all

log "Done."
kubectl --context="${CONTEXT}" get pods -n iot
