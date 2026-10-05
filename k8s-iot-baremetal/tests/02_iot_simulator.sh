#!/bin/bash
# Project: k8s-iot-baremetal
# Description: IoT sensor simulator — publishes temperature and humidity readings
#              to Mosquitto via MQTT every second. Logs all published messages.
#              Requires: mosquitto_pub installed locally.
# Author: Mauro A. Pereira

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env not found at ${ENV_FILE}. Copy .env.example and fill in the values."
    exit 1
fi
source "$ENV_FILE"

[ -z "$MQTT_BROKER_HOST" ] && echo "ERROR: MQTT_BROKER_HOST is not set in .env" && exit 1

# ── Simulator parameters ──────────────────────────────────────────────────────
BROKER_HOST="$MQTT_BROKER_HOST"
BROKER_PORT="1883"
DEVICE_ID="esp32-01"
LOCATION="sala"
TOPIC="sensors/${LOCATION}"
INTERVAL_SECS=1

# ── Sensor value ranges ───────────────────────────────────────────────────────
TEMP_MIN=19
TEMP_MAX=26
HUMIDITY_MIN=60
HUMIDITY_MAX=80
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "${SCRIPT_DIR}/../logs"
LOG_FILE="${SCRIPT_DIR}/../logs/02_iot_simulator.log"
exec > >(tee >(stdbuf -oL sed 's/\x1b\[[0-9;]*m//g' > "$LOG_FILE")) 2>&1

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +'%H:%M:%S')] $1${NC}"; }
ok()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
fail() { echo -e "${RED}[$(date +'%H:%M:%S')] $1${NC}"; exit 1; }

# ── Check dependencies ────────────────────────────────────────────────────────
if ! command -v mosquitto_pub &> /dev/null; then
    fail "mosquitto_pub not found. Install with: sudo apt install mosquitto-clients"
fi

# ── Check connectivity ────────────────────────────────────────────────────────
log "Checking connectivity to broker at ${BROKER_HOST}:${BROKER_PORT}..."
if ! mosquitto_pub -h "$BROKER_HOST" -p "$BROKER_PORT" -t "test/ping" -m "ping" --quiet 2>/dev/null; then
    fail "Cannot connect to broker at ${BROKER_HOST}:${BROKER_PORT}."
fi
ok "Broker reachable."

echo ""
log "Starting IoT simulator — device: ${DEVICE_ID}, location: ${LOCATION}, topic: ${TOPIC}"
log "Publishing every ${INTERVAL_SECS}s. Press Ctrl+C to stop."
echo ""

# ── Publish loop ──────────────────────────────────────────────────────────────
while true; do
    TEMPERATURA=$(awk -v min=$TEMP_MIN -v max=$TEMP_MAX 'BEGIN{srand(); printf "%.1f", min + rand() * (max - min)}')
    HUMEDAD=$(awk -v min=$HUMIDITY_MIN -v max=$HUMIDITY_MAX 'BEGIN{srand(); printf "%.1f", min + rand() * (max - min)}')

    PAYLOAD="{\"device_id\": \"${DEVICE_ID}\", \"location\": \"${LOCATION}\", \"temperatura\": ${TEMPERATURA}, \"humedad\": ${HUMEDAD}}"

    mosquitto_pub -h "$BROKER_HOST" -p "$BROKER_PORT" -t "$TOPIC" -m "$PAYLOAD" --quiet
    ok "Published → ${PAYLOAD}"

    sleep "$INTERVAL_SECS"
done
