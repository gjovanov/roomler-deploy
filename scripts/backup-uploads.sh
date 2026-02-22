#!/bin/bash
# =============================================================================
# Daily uploads backup — rsync with hard-link rotation
# =============================================================================
set -euo pipefail

SSH_KEY="/home/gjovanov/k8s-cluster/files/ssh/k8s_ed25519"
WORKER1="ubuntu@10.10.10.11"
SOURCE_PATH="/data/roomler/uploads/"
BACKUP_DIR="/home/gjovanov/roomler-deploy/backup/uploads"
DATE=$(date +%Y-%m-%d)
LATEST="$BACKUP_DIR/latest"
KEEP_DAYS=7

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

mkdir -p "$BACKUP_DIR"

# rsync with hard-links to previous backup (saves space for unchanged files)
LINK_DEST=""
if [ -d "$LATEST" ]; then
  LINK_DEST="--link-dest=$LATEST"
fi

rsync -av $LINK_DEST \
  -e "ssh $SSH_OPTS" \
  "$WORKER1:$SOURCE_PATH" \
  "$BACKUP_DIR/$DATE/"

# Update latest symlink
ln -snf "$BACKUP_DIR/$DATE" "$LATEST"

# Rotate old backups
find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" -mtime +$KEEP_DAYS -exec rm -rf {} +

echo "$(date '+%Y-%m-%d %H:%M:%S') Uploads backup OK: $(du -sh "$BACKUP_DIR/$DATE" | cut -f1)"
