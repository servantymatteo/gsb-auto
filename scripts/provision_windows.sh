#!/bin/bash
set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

VM_NAME="$1"
VM_IP="$2"
PLAYBOOK="$3"
WIN_USER="$4"
WIN_PASSWORD="$5"
AD_DOMAIN_NAME="${6:-gsb.local}"
AD_DOMAIN_NETBIOS="${7:-GSB}"
AD_SAFE_MODE_PASSWORD="${8:-Formation13@}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_CONFIG="$PROJECT_ROOT/ansible/ansible.cfg"

echo ""
echo -e "${BOLD}${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║    PROVISIONNEMENT WINDOWS (WINRM)     ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ -z "$VM_IP" ]]; then
  echo -e "${RED}✗ IP Windows introuvable${NC}"
  exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo -e "${RED}✗ ansible-playbook non installé${NC}"
  exit 1
fi

echo -e "${BLUE}[INFO]${NC} Cible   : ${YELLOW}${VM_IP}${NC}"
echo -e "${BLUE}[INFO]${NC} Login   : ${YELLOW}${WIN_USER}${NC}"
echo -e "${BLUE}[INFO]${NC} Playbook: ${YELLOW}${PLAYBOOK}${NC}"
echo ""

echo -e "${BLUE}[INFO]${NC} Attente WinRM (port 5985)..."
for i in {1..60}; do
  if (echo > /dev/tcp/"$VM_IP"/5985) >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} WinRM est joignable"
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo -e "${RED}[ERROR]${NC} WinRM indisponible sur ${VM_IP}:5985"
    exit 1
  fi
  sleep 10
done

ANSIBLE_FORCE_COLOR=1 ANSIBLE_CONFIG="$ANSIBLE_CONFIG" ansible-playbook \
  -i "${VM_IP}," \
  "$PLAYBOOK" \
  -e "ansible_connection=winrm" \
  -e "ansible_port=5985" \
  -e "ansible_winrm_transport=ntlm" \
  -e "ansible_winrm_server_cert_validation=ignore" \
  -e "ansible_user=${WIN_USER}" \
  -e "ansible_password=${WIN_PASSWORD}" \
  -e "ad_domain_name=${AD_DOMAIN_NAME}" \
  -e "ad_domain_netbios=${AD_DOMAIN_NETBIOS}" \
  -e "ad_safe_mode_password=${AD_SAFE_MODE_PASSWORD}"

echo ""
echo -e "${GREEN}[OK]${NC} Provisionnement Windows terminé (${VM_NAME})"
