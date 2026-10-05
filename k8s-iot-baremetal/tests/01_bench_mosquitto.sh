#!/bin/bash
# Project: k8s-iot-baremetal
# Description: Benchmark Mosquitto broker via port-forward.
#              Installs mqtt-benchmark (Go) if not present.
#              Requires: kubectl port-forward svc/mosquitto 1883:1883 -n iot
# Author: Mauro A. Pereira

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# ── Benchmark parameters ───────────────────────────────────────────────────────
BROKER="tcp://localhost:1883"
CLIENTS=20           # simulated IoT devices
COUNT=120            # messages per client — at 1 msg/sec = ~2 min runtime
SIZE=64              # bytes — typical IoT sensor payload
INTERVAL_SECS=1      # seconds between messages (integer only, tool limitation)
QOS=0
# ──────────────────────────────────────────────────────────────────────────────

# ── Industry reference values ─────────────────────────────────────────────────
# Source: https://www.javacodegeeks.com/2025/08/mqtt-brokers-at-scale-performance-tuning-mosquitto-hivemq-and-emqx.html
# Date:   August 2025
REF_LATENCY_MEAN_MAX=10    # ms — <10 ms considered good
REF_LATENCY_MAX_MAX=10     # ms — <10 ms considered good
REF_RATIO_MIN=1.000        # delivery ratio — 1.000 is optimal
# ──────────────────────────────────────────────────────────────────────────────

BENCH_BIN="$(go env GOPATH)/bin/mqtt-benchmark"
BENCH_TMP="$(mktemp)"

mkdir -p "${SCRIPT_DIR}/../logs"
LOG_FILE="${SCRIPT_DIR}/../logs/01_bench_mosquitto.log"
exec > >(tee >(stdbuf -oL sed 's/\x1b\[[0-9;]*m//g' > "$LOG_FILE")) 2>&1

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()    { echo -e "${CYAN}[$(date +'%H:%M:%S')] $1${NC}"; }
ok()     { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
fail()   { echo -e "${RED}[$(date +'%H:%M:%S')] $1${NC}"; exit 1; }
warn()   { echo -e "${YELLOW}[$(date +'%H:%M:%S')] $1${NC}"; }

check() {
    local label="$1" actual="$2" reference="$3" unit="$4" mode="$5"
    # mode: "lte" = actual must be <= reference | "gte" = actual must be >= reference
    local pass
    if [ "$mode" = "lte" ]; then
        pass=$(awk "BEGIN { print ($actual <= $reference) ? 1 : 0 }")
    else
        pass=$(awk "BEGIN { print ($actual >= $reference) ? 1 : 0 }")
    fi

    if [ "$pass" = "1" ]; then
        ok "  ${label}: ${actual} ${unit}  →  ref: ${mode/lte/\<}${mode/gte/\>}= ${reference} ${unit}  ✓"
    else
        warn "  ${label}: ${actual} ${unit}  →  ref: ${mode/lte/\<}${mode/gte/\>}= ${reference} ${unit}  ✗"
    fi
}

# ── 1. Connectivity check ─────────────────────────────────────────────────────
log "Checking connectivity to Mosquitto on localhost:1883..."
if ! nc -z localhost 1883 2>/dev/null; then
    fail "Port 1883 not reachable. Run: kubectl port-forward svc/mosquitto 1883:1883 -n iot"
fi
ok "Mosquitto reachable on localhost:1883."

# ── 2. Install mqtt-benchmark if missing ─────────────────────────────────────
if [ ! -f "$BENCH_BIN" ]; then
    log "mqtt-benchmark not found. Installing via Go..."
    go install github.com/krylovsk/mqtt-benchmark@latest
    ok "mqtt-benchmark installed at ${BENCH_BIN}."
else
    ok "mqtt-benchmark already installed."
fi

# ── 3. Run benchmark ──────────────────────────────────────────────────────────
log "Running benchmark: ${CLIENTS} clients, ${COUNT} messages each, ${SIZE}B payload, ${INTERVAL_SECS}s interval, QoS ${QOS}..."
"$BENCH_BIN" \
    -broker "$BROKER" \
    -clients "$CLIENTS" \
    -count "$COUNT" \
    -size "$SIZE" \
    -message-interval "$INTERVAL_SECS" \
    -qos "$QOS" | tee "$BENCH_TMP"

# ── 4. Compare against reference ─────────────────────────────────────────────
ACTUAL_RATIO=$(grep "Total Ratio:"      "$BENCH_TMP" | awk '{print $3}')
ACTUAL_LAT_MAX=$(grep "Msg time max"    "$BENCH_TMP" | tail -1 | awk '{print $NF}')
ACTUAL_LAT_MEAN=$(grep "Msg time mean mean" "$BENCH_TMP" | awk '{print $NF}')

echo ""
log "======= INDUSTRY REFERENCE COMPARISON ======="
log "Source: emqx.com/en/blog/open-mqtt-benchmarking-comparison-mosquitto-vs-nanomq (2024)"
check "Delivery ratio  " "$ACTUAL_RATIO"    "$REF_RATIO_MIN"        ""   "gte"
check "Latency mean    " "$ACTUAL_LAT_MEAN" "$REF_LATENCY_MEAN_MAX" "ms" "lte"
check "Latency max     " "$ACTUAL_LAT_MAX"  "$REF_LATENCY_MAX_MAX"  "ms" "lte"
echo ""

ok "Benchmark complete. Log saved to: ${LOG_FILE}"
rm -f "$BENCH_TMP"
