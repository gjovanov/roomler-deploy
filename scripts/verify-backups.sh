#!/bin/bash
# =============================================================================
# Verify backup health — run after backup or as periodic check
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
NC='\033[0m'

BACKUP_DIR="${BACKUP_BASE_PATH:?BACKUP_BASE_PATH not set in .env}"
ERRORS=0

ok()   { echo -e "${GREEN}  PASS${NC} $*"; }
fail() { echo -e "${RED}  FAIL${NC} $*"; ERRORS=$((ERRORS + 1)); }

echo -e "${CYAN}=== Backup Verification ===${NC}"
echo ""

# --- MongoDB backup ---
echo "MongoDB backups:"
MONGO_DIR="$BACKUP_DIR/mongodb"
if [ -d "$MONGO_DIR" ]; then
  LATEST_MONGO=$(ls -t "$MONGO_DIR"/roomlerdb-*.archive.gz 2>/dev/null | head -1)
  if [ -n "$LATEST_MONGO" ]; then
    AGE_HOURS=$(( ($(date +%s) - $(stat -c%Y "$LATEST_MONGO")) / 3600 ))
    SIZE=$(du -h "$LATEST_MONGO" | cut -f1)
    if [ "$AGE_HOURS" -lt 25 ]; then
      ok "Latest: $(basename "$LATEST_MONGO") ($SIZE, ${AGE_HOURS}h ago)"
    else
      fail "Latest backup is ${AGE_HOURS}h old (>24h): $(basename "$LATEST_MONGO")"
    fi
    COUNT=$(ls "$MONGO_DIR"/roomlerdb-*.archive.gz 2>/dev/null | wc -l)
    ok "Total backups: $COUNT"
  else
    fail "No MongoDB backups found in $MONGO_DIR"
  fi
else
  fail "MongoDB backup directory does not exist: $MONGO_DIR"
fi

echo ""

# --- Uploads backup ---
echo "Uploads backups:"
UPLOADS_DIR="$BACKUP_DIR/uploads"
if [ -d "$UPLOADS_DIR" ]; then
  if [ -L "$UPLOADS_DIR/latest" ] && [ -d "$UPLOADS_DIR/latest" ]; then
    LATEST_DATE=$(readlink "$UPLOADS_DIR/latest" | xargs basename)
    FILE_COUNT=$(find -L "$UPLOADS_DIR/latest" -type f 2>/dev/null | wc -l)
    SIZE=$(du -shL "$UPLOADS_DIR/latest" | cut -f1)
    ok "Latest: $LATEST_DATE ($SIZE, $FILE_COUNT files)"
  else
    fail "No 'latest' symlink in $UPLOADS_DIR"
  fi
  DIR_COUNT=$(find "$UPLOADS_DIR" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l)
  ok "Total backup snapshots: $DIR_COUNT"
else
  fail "Uploads backup directory does not exist: $UPLOADS_DIR"
fi

echo ""

# --- Total disk usage ---
echo "Disk usage:"
if [ -d "$BACKUP_DIR" ]; then
  du -sh "$BACKUP_DIR"/* 2>/dev/null | while read -r size path; do
    echo "  $size  $(basename "$path")"
  done
  echo "  ------"
  echo "  $(du -sh "$BACKUP_DIR" | cut -f1)  TOTAL"
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo -e "${GREEN}All checks passed${NC}"
else
  echo -e "${RED}$ERRORS check(s) failed${NC}"
  exit 1
fi
