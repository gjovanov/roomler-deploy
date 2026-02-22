#!/bin/bash
# =============================================================================
# Cut over from Docker to K8s
# Updates host nginx upstreams and stops Docker containers
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env
set -a
source "$PROJECT_DIR/.env"
set +a

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] OK${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] FAIL${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN${NC} $*"; }

KUBECONFIG="${KUBECONFIG_PATH:?KUBECONFIG_PATH not set in .env}"
NAMESPACE="roomler"
NGINX_CONF_DIR="${NGINX_CONF_DIR:?NGINX_CONF_DIR not set in .env}"
K8S_WORKER1_IP="${K8S_WORKER1_IP:?K8S_WORKER1_IP not set in .env}"
HOST_PUBLIC_IP="${HOST_PUBLIC_IP:?HOST_PUBLIC_IP not set in .env}"

# --- Pre-flight: verify K8s pods are healthy ---
log "Verifying K8s pods..."
if ! KUBECONFIG=$KUBECONFIG kubectl wait --for=condition=ready pods --all -n $NAMESPACE --timeout=30s 2>/dev/null; then
  err "Not all pods are ready in namespace $NAMESPACE. Aborting cutover."
  KUBECONFIG=$KUBECONFIG kubectl get pods -n $NAMESPACE
  exit 1
fi
ok "All K8s pods healthy"

# --- Test K8s Roomler service ---
log "Testing K8s Roomler service..."
if curl -sf -o /dev/null "http://$K8S_WORKER1_IP:30030/"; then
  ok "Roomler reachable at $K8S_WORKER1_IP:30030"
else
  err "Roomler NOT reachable at $K8S_WORKER1_IP:30030. Aborting."
  exit 1
fi

# --- Backup current nginx configs ---
log "Backing up nginx configs..."
BACKUP_TS=$(date +%Y%m%d-%H%M%S)
cp "$NGINX_CONF_DIR/roomler.live.conf" "$NGINX_CONF_DIR/roomler.live.conf.bak-$BACKUP_TS"
cp "$NGINX_CONF_DIR/janus.roomler.live.conf" "$NGINX_CONF_DIR/janus.roomler.live.conf.bak-$BACKUP_TS"
ok "Configs backed up with suffix .bak-$BACKUP_TS"

# --- Update nginx: roomler upstream ---
log "Updating roomler.live.conf upstream..."
sed -i "s|proxy_pass.*http://roomler2:3000;|proxy_pass         http://$K8S_WORKER1_IP:30030;|" \
  "$NGINX_CONF_DIR/roomler.live.conf"

# --- Update nginx: janus upstreams ---
log "Updating janus.roomler.live.conf upstreams..."
sed -i \
  -e "s|proxy_pass http://$HOST_PUBLIC_IP:8080;|proxy_pass http://$K8S_WORKER1_IP:30808;|" \
  -e "s|proxy_pass http://$HOST_PUBLIC_IP:8188;|proxy_pass http://$K8S_WORKER1_IP:30818;|" \
  -e "s|proxy_pass http://$HOST_PUBLIC_IP:8088/janus;|proxy_pass http://$K8S_WORKER1_IP:30808/janus;|" \
  -e "s|proxy_pass http://$HOST_PUBLIC_IP:7188;|proxy_pass http://$K8S_WORKER1_IP:30718;|" \
  -e "s|proxy_pass http://$HOST_PUBLIC_IP:7088/admin;|proxy_pass http://$K8S_WORKER1_IP:30708/admin;|" \
  "$NGINX_CONF_DIR/janus.roomler.live.conf"

# --- Test nginx config ---
log "Testing nginx configuration..."
if docker exec nginx nginx -t 2>&1; then
  ok "nginx config valid"
else
  err "nginx config invalid! Restoring backups..."
  cp "$NGINX_CONF_DIR/roomler.live.conf.bak-$BACKUP_TS" "$NGINX_CONF_DIR/roomler.live.conf"
  cp "$NGINX_CONF_DIR/janus.roomler.live.conf.bak-$BACKUP_TS" "$NGINX_CONF_DIR/janus.roomler.live.conf"
  exit 1
fi

# --- Reload nginx ---
log "Reloading nginx..."
docker exec nginx nginx -s reload
ok "nginx reloaded"

# --- Verify external access ---
log "Verifying https://roomler.live ..."
sleep 2
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" https://roomler.live/ 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  ok "roomler.live returns HTTP $HTTP_CODE"
else
  warn "roomler.live returns HTTP $HTTP_CODE — check manually"
fi

log ""
log "Cutover complete. Docker containers are still running as fallback."
log ""
log "If everything looks good, stop Docker containers:"
log "  docker stop roomler2 mongo2 redis janus"
log "  docker stop nginx2  # redundant, COTURN handled by K8s"
log ""
log "To rollback, restore nginx configs:"
log "  cp $NGINX_CONF_DIR/roomler.live.conf.bak-$BACKUP_TS $NGINX_CONF_DIR/roomler.live.conf"
log "  cp $NGINX_CONF_DIR/janus.roomler.live.conf.bak-$BACKUP_TS $NGINX_CONF_DIR/janus.roomler.live.conf"
log "  docker exec nginx nginx -s reload"
