#!/bin/bash
# Project: k8s-iot-baremetal
# Description: Create InfluxDB Secrets from .env and generate scoped tokens
#              for Telegraf (write-only) and Grafana (read-only).
#              Requires: InfluxDB already running in the cluster.
# Author: Mauro A. Pereira

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
INFLUX_NS="iot"
INFLUX_SVC="influxdb"
INFLUX_PORT="8086"

mkdir -p "${SCRIPT_DIR}/../logs"
LOG_FILE="${SCRIPT_DIR}/../logs/04_setup_influxdb.log"
exec > >(tee >(stdbuf -oL sed 's/\x1b\[[0-9;]*m//g' > "$LOG_FILE")) 2>&1

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +'%H:%M:%S')] $1${NC}"; }
ok()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
fail() { echo -e "${RED}[$(date +'%H:%M:%S')] $1${NC}"; exit 1; }

# ── 1. Load .env ──────────────────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
    fail ".env not found at ${ENV_FILE}. Copy .env.example and fill in the values."
fi
source "$ENV_FILE"

for var in INFLUXDB_ORG INFLUXDB_BUCKET INFLUXDB_USERNAME INFLUXDB_PASSWORD INFLUXDB_TOKEN; do
    [ -z "${!var}" ] && fail "${var} is not set in .env"
done
ok ".env loaded."

# ── 2. Create admin Secret ────────────────────────────────────────────────────
log "Creating influxdb-auth Secret..."
kubectl create secret generic influxdb-auth \
    -n "$INFLUX_NS" \
    --from-literal=username="$INFLUXDB_USERNAME" \
    --from-literal=password="$INFLUXDB_PASSWORD" \
    --from-literal=token="$INFLUXDB_TOKEN" \
    --from-literal=org="$INFLUXDB_ORG" \
    --from-literal=bucket="$INFLUXDB_BUCKET" \
    --dry-run=client -o yaml | kubectl apply -f -
ok "Secret 'influxdb-auth' created."

# ── 3. Wait for InfluxDB to be ready ─────────────────────────────────────────
log "Checking InfluxDB StatefulSet exists..."
if ! kubectl get statefulset influxdb -n "$INFLUX_NS" &> /dev/null; then
    fail "InfluxDB StatefulSet not found in namespace '${INFLUX_NS}'. Deploy the manifests first: git push k8s-iot-baremetal/k8s/influxdb/ and wait for ArgoCD to sync."
fi

log "Waiting for InfluxDB pod to be ready..."
kubectl wait --for=condition=ready pod \
    -l app=influxdb \
    -n "$INFLUX_NS" \
    --timeout=120s
ok "InfluxDB is ready."

# ── 4. Generate scoped tokens via InfluxDB API ───────────────────────────────
INFLUX_POD="$(kubectl get pod -n $INFLUX_NS -l app=influxdb -o jsonpath='{.items[0].metadata.name}')"

log "Fetching bucket ID..."
BUCKET_ID=$(kubectl exec -n "$INFLUX_NS" "$INFLUX_POD" \
    -- influx bucket list --token "$INFLUXDB_TOKEN" --org "$INFLUXDB_ORG" --name "$INFLUXDB_BUCKET" --json | \
    grep '"id"' | head -1 | awk -F'"' '{print $4}')
[ -z "$BUCKET_ID" ] && fail "Could not fetch bucket ID for '${INFLUXDB_BUCKET}'."
ok "Bucket ID: ${BUCKET_ID}"

log "Generating Telegraf write-only token..."
TELEGRAF_TOKEN=$(kubectl exec -n "$INFLUX_NS" "$INFLUX_POD" \
    -- influx auth create \
        --token "$INFLUXDB_TOKEN" \
        --org "$INFLUXDB_ORG" \
        --write-bucket "$BUCKET_ID" \
        --description "telegraf-write" \
        --json | grep '"token"' | awk -F'"' '{print $4}')
[ -z "$TELEGRAF_TOKEN" ] && fail "Could not generate Telegraf token."
ok "Telegraf token generated."

log "Generating Grafana read-only token..."
GRAFANA_TOKEN=$(kubectl exec -n "$INFLUX_NS" "$INFLUX_POD" \
    -- influx auth create \
        --token "$INFLUXDB_TOKEN" \
        --org "$INFLUXDB_ORG" \
        --read-bucket "$BUCKET_ID" \
        --description "grafana-read" \
        --json | grep '"token"' | awk -F'"' '{print $4}')
[ -z "$GRAFANA_TOKEN" ] && fail "Could not generate Grafana token."
ok "Grafana token generated."

# ── 5. Save scoped tokens as Secrets ─────────────────────────────────────────
log "Creating influxdb-token-telegraf Secret..."
kubectl create secret generic influxdb-token-telegraf \
    -n "$INFLUX_NS" \
    --from-literal=token="$TELEGRAF_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
ok "Secret 'influxdb-token-telegraf' created."

log "Creating influxdb-token-grafana Secret..."
kubectl create secret generic influxdb-token-grafana \
    -n "$INFLUX_NS" \
    --from-literal=token="$GRAFANA_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
ok "Secret 'influxdb-token-grafana' created."

echo ""
ok "======= InfluxDB Secrets ready ======="
ok "  influxdb-auth            → admin credentials"
ok "  influxdb-token-telegraf  → write-only to ${INFLUXDB_BUCKET}"
ok "  influxdb-token-grafana   → read-only from ${INFLUXDB_BUCKET}"
