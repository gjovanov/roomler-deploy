#!/bin/bash
# =============================================================================
# Deploy Roomler stack to K8s
# Runs Ansible playbook and logs timing
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Source .env and export all vars
set -a
source "$PROJECT_DIR/.env"
set +a

log() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] OK${NC} $*"; }
err() { echo -e "${RED}[$(date '+%H:%M:%S')] FAIL${NC} $*"; }

START=$(date +%s)

log "Deploying Roomler stack to K8s..."
cd "$PROJECT_DIR" && ansible-playbook playbooks/deploy.yml -v

END=$(date +%s)
DUR=$((END - START))

ok "Deployment completed in ${DUR}s"
log ""
log "Next steps:"
log "  1. Run: ./scripts/restore-mongodb.sh  (if first deploy, to restore data)"
log "  2. Update host nginx upstreams to K8s NodePorts"
log "  3. Verify: curl -I https://roomler.live"
log "  4. Stop Docker containers: cd /gjovanov/roomler && docker compose down"
