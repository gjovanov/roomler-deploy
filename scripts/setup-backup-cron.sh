#!/bin/bash
# =============================================================================
# Install backup cron jobs
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env
set -a
source "$PROJECT_DIR/.env"
set +a

echo "Installing backup cron jobs..."

# Build cron entries
LOG_FILE="${BACKUP_BASE_PATH:?BACKUP_BASE_PATH not set in .env}/backup.log"
MONGO_CRON="0 3 * * * $SCRIPT_DIR/backup-mongodb.sh >> $LOG_FILE 2>&1"
UPLOADS_CRON="30 3 * * * $SCRIPT_DIR/backup-uploads.sh >> $LOG_FILE 2>&1"
VERIFY_CRON="0 4 * * * $SCRIPT_DIR/verify-backups.sh >> $LOG_FILE 2>&1"

# Add to crontab if not already present
# (grep -v returns 1 when no lines match, so use || true)
{
  crontab -l 2>/dev/null | grep -v "backup-mongodb.sh" | grep -v "backup-uploads.sh" | grep -v "verify-backups.sh" || true
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
