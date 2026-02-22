#!/bin/bash
# =============================================================================
# Daily MongoDB backup — run via cron
# Dumps roomlerdb from K8s pod, rotates old backups
# =============================================================================
set -euo pipefail

KUBECONFIG="/home/gjovanov/k8s-cluster/files/kubeconfig"
NAMESPACE="roomler"
BACKUP_DIR="/home/gjovanov/roomler-deploy/backup/mongodb"
DATE=$(date +%Y-%m-%d)
KEEP_DAYS=7

mkdir -p "$BACKUP_DIR"

# Dump from K8s pod
KUBECONFIG=$KUBECONFIG kubectl exec mongodb-0 -n $NAMESPACE -- \
  mongodump --db roomlerdb --archive --gzip \
  > "$BACKUP_DIR/roomlerdb-$DATE.archive.gz"

# Verify dump is non-empty
SIZE=$(stat -c%s "$BACKUP_DIR/roomlerdb-$DATE.archive.gz" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 1000 ]; then
  echo "ERROR: Backup file too small (${SIZE} bytes), possible failure" >&2
  exit 1
fi

# Rotate old backups
find "$BACKUP_DIR" -name "*.archive.gz" -mtime +$KEEP_DAYS -delete

echo "$(date '+%Y-%m-%d %H:%M:%S') MongoDB backup OK: $(du -h "$BACKUP_DIR/roomlerdb-$DATE.archive.gz" | cut -f1)"
