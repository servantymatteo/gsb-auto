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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SSH_KEY="$PROJECT_ROOT/ssh/id_ed25519_terraform"
if [[ ! -f "$SSH_KEY" ]]; then
  if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    SSH_KEY="$HOME/.ssh/id_ed25519"
  elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
    SSH_KEY="$HOME/.ssh/id_rsa"
  else
    echo -e "${RED}   ✗ Clé SSH introuvable (attendue: $PROJECT_ROOT/ssh/id_ed25519_terraform ou ~/.ssh/*)${NC}"
    exit 1
  fi
fi
ANSIBLE_CONFIG="$PROJECT_ROOT/ansible/ansible.cfg"

CONTAINER_NAME="$1"
CONTAINER_IP="$2"
PLAYBOOK="$3"

echo ""
echo -e "${BOLD}${MAGENTA}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${MAGENTA}║   PROVISIONNEMENT TERRAFORM + ANSIBLE  ║${NC}"
echo -e "${BOLD}${MAGENTA}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ -z "$CONTAINER_IP" ]]; then
  echo -e "${RED}   ✗ IP non fournie par Terraform${NC}"
  exit 1
fi

echo -e "${CYAN}→ [1/3] Test de la connexion SSH...${NC}"
for i in {1..20}; do
  if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@"$CONTAINER_IP" 'exit' 2>/dev/null; then
    echo -e "${GREEN}   ✓ SSH opérationnel${NC}"
    break
  fi
  if [[ $i -eq 20 ]]; then
    echo -e "${RED}   ✗ SSH timeout${NC}"
    exit 1
  fi
  sleep 3
done
echo ""

echo -e "${CYAN}→ [2/3] Vérification Ansible...${NC}"
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo -e "${RED}   ✗ Ansible non installé${NC}"
  exit 1
fi
echo -e "${GREEN}   ✓ Ansible disponible${NC}"
echo ""

echo -e "${CYAN}→ [3/3] Provisionnement (Ansible)...${NC}"
echo -e "${YELLOW}   • Cible: ${BOLD}$CONTAINER_IP${NC}"
echo -e "${YELLOW}   • Playbook: ${BOLD}$PLAYBOOK${NC}"
echo ""

ANSIBLE_FORCE_COLOR=1 ANSIBLE_CONFIG="$ANSIBLE_CONFIG" ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  --private-key="$SSH_KEY" \
  -i "$CONTAINER_IP," \
  -u root \
  "$PLAYBOOK"

echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         DÉPLOIEMENT RÉUSSI ! ✓         ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}🌐 Container: ${BOLD}${YELLOW}$CONTAINER_NAME${NC}"
echo -e "${CYAN}🌐 IP:        ${BOLD}${YELLOW}$CONTAINER_IP${NC}"
echo ""
