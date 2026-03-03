#!/bin/bash
set -e

BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  DÉPLOIEMENT LOCAL (wrapper setup.sh)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ ! -f "./setup.sh" ]; then
    echo -e "${RED}✗ setup.sh introuvable${NC}" >&2
    exit 1
fi

if [ ! -x "./setup.sh" ]; then
    chmod +x ./setup.sh
fi

echo -e "${YELLOW}Ce script est conservé pour compatibilité.${NC}"
echo -e "${YELLOW}Le flux principal est maintenant géré par setup.sh.${NC}"
echo ""

exec ./setup.sh
