#!/bin/bash
# =============================================================================
# Migrate data from Docker containers to K8s worker node
# Run BEFORE deploy.sh — copies MongoDB dump and uploads to k8s-worker1
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env
set -a
source "$PROJECT_DIR/.env"
set +a

SSH_KEY="/home/gjovanov/k8s-cluster/files/ssh/k8s_ed25519"
WORKER1="ubuntu@10.10.10.11"
DATA_DIR="/data/roomler"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] OK${NC} $*"; }
err() { echo -e "${RED}[$(date '+%H:%M:%S')] FAIL${NC} $*"; }

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# --- Create target directories on worker ---
log "Creating data directories on k8s-worker1..."
ssh $SSH_OPTS $WORKER1 "sudo mkdir -p $DATA_DIR/{mongodb,uploads} && sudo chown -R ubuntu:ubuntu $DATA_DIR"

# --- MongoDB dump ---
log "Dumping MongoDB from Docker container 'mongo2'..."
DUMP_FILE="/tmp/roomlerdb-$(date +%Y%m%d).archive"

docker exec mongo2 mongodump \
  --db roomlerdb \
  --archive=/tmp/roomlerdb.archive \
  --gzip 2>&1

docker cp mongo2:/tmp/roomlerdb.archive "$DUMP_FILE.gz"
ok "MongoDB dump: $DUMP_FILE.gz ($(du -h "$DUMP_FILE.gz" | cut -f1))"

log "Copying MongoDB dump to k8s-worker1..."
scp $SSH_OPTS "$DUMP_FILE.gz" "$WORKER1:$DATA_DIR/roomlerdb.archive.gz"
ok "MongoDB dump transferred"

# --- Uploads ---
log "Syncing uploads to k8s-worker1..."
rsync -av --progress \
  -e "ssh $SSH_OPTS" \
  /roomler/uploads/ \
  "$WORKER1:$DATA_DIR/uploads/"
ok "Uploads synced ($(ssh $SSH_OPTS $WORKER1 "du -sh $DATA_DIR/uploads" | cut -f1))"

# --- Summary ---
log ""
log "Migration complete. Data on k8s-worker1:"
ssh $SSH_OPTS $WORKER1 "du -sh $DATA_DIR/*"
log ""
log "Next step: run ./scripts/deploy.sh"
