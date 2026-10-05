#!/bin/bash
# Project: k8s-iot-baremetal
# Description: Full smoke test for Mosquitto broker.
#              Runs the Job with broker up, down, and up again to validate
#              both the test detection and broker recovery.
# Author: Mauro A. Pereira
#
# Alternative (no Job manifest):
#   kubectl run mqtt-test --rm -it --restart=Never --image=eclipse-mosquitto -n iot \
#     -- sh -c "mosquitto_sub -h mosquitto -t test/smoke -C 1 & sleep 1 && mosquitto_pub -h mosquitto -t test/smoke -m ok && wait"

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
JOB_MANIFEST="${SCRIPT_DIR}/../k8s/mosquitto/smoke-test.yml"
NAMESPACE="iot"
JOB_NAME="mosquitto-smoke-test"

mkdir -p "${SCRIPT_DIR}/../logs"
LOG_FILE="${SCRIPT_DIR}/../logs/00_test_mosquitto.log"
exec > >(tee >(stdbuf -oL sed 's/\x1b\[[0-9;]*m//g' > "$LOG_FILE")) 2>&1

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +'%H:%M:%S')] $1${NC}"; }
ok()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
fail() { echo -e "${RED}[$(date +'%H:%M:%S')] $1${NC}"; }

show_pods() {
    echo ""
    kubectl get pods -n "$NAMESPACE"
    echo ""
}

run_job() {
    kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found > /dev/null
    kubectl apply -f "$JOB_MANIFEST" > /dev/null

    log "Waiting for Job to finish..."
    PASSED=false
    for i in $(seq 1 15); do
        STATUS=$(kubectl get pods -n "$NAMESPACE" -l "job-name=$JOB_NAME" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        if [ "$STATUS" = "Succeeded" ]; then PASSED=true; break; fi
        [ "$STATUS" = "Failed" ] && break
        sleep 2
    done

    show_pods
    log "Logs:"
    kubectl logs -n "$NAMESPACE" "job/${JOB_NAME}" 2>/dev/null || true
    kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found > /dev/null

    if [ "$PASSED" = "true" ]; then
        ok "Result: PASSED"
    else
        fail "Result: FAILED"
    fi
    echo ""
}

# ── Round 1: broker up → expect PASS ──────────────────────────────────────────
log "Round 1: broker running — smoke test should PASS"
show_pods
run_job

# ── Round 2: broker down → expect FAIL ───────────────────────────────────────
log "Round 2: scaling down broker — smoke test should FAIL"
kubectl scale deployment mosquitto -n "$NAMESPACE" --replicas=0 > /dev/null
log "Waiting for broker pod to terminate..."
kubectl wait --for=delete pod -l app=mosquitto -n "$NAMESPACE" --timeout=30s > /dev/null
show_pods
run_job

# ── Round 3: broker back up → expect PASS ────────────────────────────────────
log "Round 3: scaling broker back up — smoke test should PASS"
kubectl scale deployment mosquitto -n "$NAMESPACE" --replicas=1 > /dev/null
log "Waiting for broker to be ready..."
kubectl wait --for=condition=available deployment/mosquitto -n "$NAMESPACE" --timeout=60s > /dev/null
show_pods
run_job

ok "All rounds complete. Broker is running."
