#!/bin/bash
# =============================================================================
# Install backup cron jobs
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing backup cron jobs..."

# Build cron entries
MONGO_CRON="0 3 * * * $SCRIPT_DIR/backup-mongodb.sh >> /var/log/roomler-backup.log 2>&1"
UPLOADS_CRON="30 3 * * * $SCRIPT_DIR/backup-uploads.sh >> /var/log/roomler-backup.log 2>&1"
VERIFY_CRON="0 4 * * * $SCRIPT_DIR/verify-backups.sh >> /var/log/roomler-backup.log 2>&1"

# Add to crontab if not already present
(crontab -l 2>/dev/null || true) | {
  grep -v "backup-mongodb.sh" | grep -v "backup-uploads.sh" | grep -v "verify-backups.sh"
} | {
  cat
  echo "$MONGO_CRON"
  echo "$UPLOADS_CRON"
  echo "$VERIFY_CRON"
} | crontab -

echo "Cron jobs installed:"
echo "  03:00 — MongoDB backup"
echo "  03:30 — Uploads backup"
echo "  04:00 — Backup verification"
echo ""
echo "Current crontab:"
crontab -l
