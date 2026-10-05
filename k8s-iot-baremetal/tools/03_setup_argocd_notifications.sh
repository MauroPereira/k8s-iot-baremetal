#!/bin/bash
# Project: k8s-iot-baremetal
# Description: Configure ArgoCD Notifications to send alerts to Discord.
#              Reads the webhook URL from k8s-iot-baremetal/.env
#              Requires: 01_setup_argocd.sh already executed.
# Author: Mauro A. Pereira

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
ARGOCD_NS="argocd"
APPS=("iot-pipeline" "cluster-storage")

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

if [ -z "$DISCORD_WEBHOOK_URL" ]; then
    fail "DISCORD_WEBHOOK_URL is not set in .env"
fi
ok ".env loaded."

# ── 2. Patch Secret with webhook URL ─────────────────────────────────────────
log "Storing Discord webhook in argocd-notifications-secret..."
kubectl patch secret argocd-notifications-secret -n "$ARGOCD_NS" \
    --type=merge \
    -p "{\"stringData\": {\"discord-webhook\": \"${DISCORD_WEBHOOK_URL}\"}}"
ok "Secret updated."

# ── 3. Configure notifications service, templates and triggers ───────────────
log "Applying notifications ConfigMap..."
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.webhook.discord: |
    url: $discord-webhook
    headers:
      - name: Content-Type
        value: application/json

  template.app-sync-succeeded: |
    webhook:
      discord:
        method: POST
        body: |
          {
            "embeds": [{
              "title": "✅ Sync Succeeded — {{.app.metadata.name}}",
              "description": "**Revision:** `{{.app.status.operationState.syncResult.revision | substr 0 7}}`\n**Images:**\n{{range .app.status.summary.images}}`{{.}}`\n{{end}}",
              "color": 3066993
            }]
          }

  template.app-sync-failed: |
    webhook:
      discord:
        method: POST
        body: |
          {
            "embeds": [{
              "title": "❌ Sync Failed — {{.app.metadata.name}}",
              "description": "**Error:** {{.app.status.operationState.message}}\n**Failed resources:**\n{{range .app.status.operationState.syncResult.resources}}{{if eq .status "Failed"}}`{{.kind}}/{{.name}}`: {{.message}}\n{{end}}{{end}}",
              "color": 15158332
            }]
          }

  template.app-health-degraded: |
    webhook:
      discord:
        method: POST
        body: |
          {
            "embeds": [{
              "title": "⚠️ Health Degraded — {{.app.metadata.name}}",
              "description": "**Health:** {{.app.status.health.status}}\n**Revision:** `{{.app.status.sync.revision | substr 0 7}}`",
              "color": 15105570
            }]
          }

  trigger.on-sync-succeeded: |
    - when: app.status.operationState.phase in ['Succeeded']
      send: [app-sync-succeeded]

  trigger.on-sync-failed: |
    - when: app.status.operationState.phase in ['Error', 'Failed']
      send: [app-sync-failed]

  trigger.on-health-degraded: |
    - when: app.status.health.status == 'Degraded'
      send: [app-health-degraded]
EOF
ok "ConfigMap applied."

# ── 4. Subscribe Applications to triggers ────────────────────────────────────
for app in "${APPS[@]}"; do
    log "Subscribing '${app}' to notification triggers..."
    kubectl patch application "$app" -n "$ARGOCD_NS" \
        --type=merge \
        -p '{
          "metadata": {
            "annotations": {
              "notifications.argoproj.io/subscribe.on-sync-succeeded.discord": "",
              "notifications.argoproj.io/subscribe.on-sync-failed.discord": "",
              "notifications.argoproj.io/subscribe.on-health-degraded.discord": ""
            }
          }
        }'
    ok "Application '${app}' subscribed to triggers."
done

echo ""
ok "ArgoCD Notifications configured."
log "Discord alerts active for: sync-succeeded, sync-failed, health-degraded."
