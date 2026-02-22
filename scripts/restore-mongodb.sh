#!/bin/bash
# =============================================================================
# Restore MongoDB data inside K8s pod
# Run AFTER deploy.sh has created the MongoDB StatefulSet
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env
set -a
source "$PROJECT_DIR/.env"
set +a

KUBECONFIG="${KUBECONFIG_PATH:?KUBECONFIG_PATH not set in .env}"
NAMESPACE="roomler"
SSH_KEY="${SSH_KEY_PATH:?SSH_KEY_PATH not set in .env}"
WORKER1="${K8S_SSH_USER:?K8S_SSH_USER not set in .env}@${K8S_WORKER1_IP:?K8S_WORKER1_IP not set in .env}"
DATA_DIR="/data/roomler"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] OK${NC} $*"; }
err() { echo -e "${RED}[$(date '+%H:%M:%S')] FAIL${NC} $*"; }

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Check MongoDB pod is ready
log "Checking MongoDB pod..."
KUBECONFIG=$KUBECONFIG kubectl wait --for=condition=ready pod/mongodb-0 -n $NAMESPACE --timeout=60s

# Check if data already exists
DOC_COUNT=$(KUBECONFIG=$KUBECONFIG kubectl exec mongodb-0 -n $NAMESPACE -- \
  mongosh --quiet --eval "db.getSiblingDB('roomlerdb').getCollectionNames().length" 2>/dev/null || echo "0")

if [ "$DOC_COUNT" != "0" ] && [ "$DOC_COUNT" != "" ]; then
  log "MongoDB already has data ($DOC_COUNT collections). Skipping restore."
  log "To force restore, drop the database first:"
  log "  KUBECONFIG=$KUBECONFIG kubectl exec mongodb-0 -n $NAMESPACE -- mongosh --eval 'db.getSiblingDB(\"roomlerdb\").dropDatabase()'"
  exit 0
fi

# Copy archive into pod
log "Copying dump archive into MongoDB pod..."
KUBECONFIG=$KUBECONFIG kubectl cp "$DATA_DIR/roomlerdb.archive.gz" \
  "$NAMESPACE/mongodb-0:/tmp/roomlerdb.archive.gz" 2>/dev/null || {
  # kubectl cp might fail, try via worker node
  log "Direct cp failed, restoring via worker node..."
  ssh $SSH_OPTS $WORKER1 "sudo cp $DATA_DIR/roomlerdb.archive.gz /data/roomler/mongodb/roomlerdb.archive.gz"
  KUBECONFIG=$KUBECONFIG kubectl exec mongodb-0 -n $NAMESPACE -- \
    cp /data/db/roomlerdb.archive.gz /tmp/roomlerdb.archive.gz
}

# Restore
log "Restoring MongoDB data..."
KUBECONFIG=$KUBECONFIG kubectl exec mongodb-0 -n $NAMESPACE -- \
  mongorestore --archive=/tmp/roomlerdb.archive.gz --gzip --drop 2>&1

# Verify
log "Verifying restore..."
KUBECONFIG=$KUBECONFIG kubectl exec mongodb-0 -n $NAMESPACE -- \
  mongosh --quiet --eval "
    const db = db.getSiblingDB('roomlerdb');
    const colls = db.getCollectionNames();
    print('Collections: ' + colls.length);
    colls.forEach(c => print('  ' + c + ': ' + db[c].countDocuments() + ' docs'));
  "

# Cleanup
KUBECONFIG=$KUBECONFIG kubectl exec mongodb-0 -n $NAMESPACE -- rm -f /tmp/roomlerdb.archive.gz

ok "MongoDB restore complete"
