#!/bin/bash
set -e

# Couleurs
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Chemins relatifs depuis le dossier scripts/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SSH_KEY="$PROJECT_ROOT/ssh/id_ed25519_terraform"
ANSIBLE_CONFIG="$PROJECT_ROOT/ansible/ansible.cfg"

echo ""
echo -e "${BOLD}${MAGENTA}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${MAGENTA}║   PROVISIONNEMENT TERRAFORM + ANSIBLE  ║${NC}"
echo -e "${BOLD}${MAGENTA}╚════════════════════════════════════════╝${NC}"
echo ""

# [1/4] Attente du démarrage du container
echo -e "${CYAN}→ [1/4] Démarrage du container...${NC}"
sleep 25
echo -e "${GREEN}   ✓ Container démarré${NC}"
echo ""

# [2/4] Récupération des informations du container
echo -e "${CYAN}→ [2/4] Récupération des informations...${NC}"
CONTAINER_NAME="$1"
API_BASE_URL="$2"
API_TOKEN_ID="$3"
API_TOKEN_SECRET="$4"
TARGET_NODE="$5"
PLAYBOOK="$6"

API_BASE_URL="${API_BASE_URL%/api2/json}"

RESPONSE=$(curl -k -s -H "Authorization: PVEAPIToken=${API_TOKEN_ID}=${API_TOKEN_SECRET}" \
  "$API_BASE_URL/api2/json/nodes/${TARGET_NODE}/lxc" 2>/dev/null)

VMID=$(echo "$RESPONSE" | grep -o "{[^}]*\"name\":\"$CONTAINER_NAME\"[^}]*}" | \
  grep -o "\"vmid\":[0-9]*" | grep -o "[0-9]*" | sort -n | tail -1)

echo -e "${GREEN}   ✓ VMID: ${YELLOW}$VMID${NC}"

CONTAINER_IP=""
for i in {1..10}; do
  NETWORK_RESPONSE=$(curl -k -s -H "Authorization: PVEAPIToken=${API_TOKEN_ID}=${API_TOKEN_SECRET}" \
    "$API_BASE_URL/api2/json/nodes/${TARGET_NODE}/lxc/$VMID/interfaces" 2>/dev/null)
  CONTAINER_IP=$(echo "$NETWORK_RESPONSE" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v "127.0.0.1" | head -1)
  [ -n "$CONTAINER_IP" ] && break
  sleep 2
done

[ -z "$CONTAINER_IP" ] && { echo -e "${RED}   ✗ IP non trouvée${NC}"; exit 1; }
echo -e "${GREEN}   ✓ IP: ${YELLOW}$CONTAINER_IP${NC}"
echo ""

# [3/4] Test de connectivité SSH
echo -e "${CYAN}→ [3/4] Test de la connexion SSH...${NC}"
for i in {1..20}; do
  if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     root@$CONTAINER_IP 'exit' 2>/dev/null; then
    echo -e "${GREEN}   ✓ SSH opérationnel${NC}"
    break
  fi
  [ $i -eq 20 ] && { echo -e "${RED}   ✗ SSH timeout${NC}"; exit 1; }
  sleep 3
done
echo ""

# [4/4] Provisionnement via Ansible
echo -e "${CYAN}→ [4/4] Provisionnement (Ansible)...${NC}"

if ! command -v ansible-playbook &> /dev/null; then
  echo -e "${RED}   ✗ Ansible non installé${NC}"
  exit 1
fi

echo -e "${YELLOW}   • Cible: ${BOLD}$CONTAINER_IP${NC}"
echo -e "${YELLOW}   • Playbook: ${BOLD}$PLAYBOOK${NC}"
echo ""

ANSIBLE_FORCE_COLOR=1 ANSIBLE_CONFIG="$ANSIBLE_CONFIG" ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  --private-key="$SSH_KEY" \
  -i "$CONTAINER_IP," \
  -u root \
  "$PLAYBOOK"

if [ $? -eq 0 ]; then
  echo ""
  echo -e "${BOLD}${GREEN}╔════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║         DÉPLOIEMENT RÉUSSI ! ✓         ║${NC}"
  echo -e "${BOLD}${GREEN}╚════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${CYAN}🌐 Container: ${BOLD}${YELLOW}$CONTAINER_NAME${NC}"
  echo -e "${CYAN}🌐 IP:        ${BOLD}${YELLOW}$CONTAINER_IP${NC}"
  echo ""
else
  echo ""
  echo -e "${BOLD}${RED}✗ Échec du provisionnement${NC}"
  exit 1
fi
