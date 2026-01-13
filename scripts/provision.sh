#!/bin/bash
set -e

# Charger les fonctions communes
source "$(dirname "$0")/common.sh"

print_header "PROVISIONNEMENT TERRAFORM + ANSIBLE" "$MAGENTA"

# Paramètres
CONTAINER_NAME="$1"
API_BASE_URL="${2%/api2/json}"
API_TOKEN_ID="$3"
API_TOKEN_SECRET="$4"
TARGET_NODE="$5"
PLAYBOOK="$6"

# [1/4] Attente du démarrage
info "[1/4] Démarrage du container..."
sleep 25
success "Container démarré"
echo ""

# [2/4] Récupération VMID et IP
info "[2/4] Récupération des informations..."

RESPONSE=$(curl -k -s -H "Authorization: PVEAPIToken=${API_TOKEN_ID}=${API_TOKEN_SECRET}" \
  "$API_BASE_URL/api2/json/nodes/${TARGET_NODE}/lxc" 2>/dev/null)

VMID=$(echo "$RESPONSE" | grep -o "{[^}]*\"name\":\"$CONTAINER_NAME\"[^}]*}" | \
  grep -o "\"vmid\":[0-9]*" | grep -o "[0-9]*" | sort -n | tail -1)

success "VMID: ${YELLOW}$VMID${NC}"

# Récupération IP avec retry
CONTAINER_IP=""
for i in {1..10}; do
  NETWORK_RESPONSE=$(curl -k -s -H "Authorization: PVEAPIToken=${API_TOKEN_ID}=${API_TOKEN_SECRET}" \
    "$API_BASE_URL/api2/json/nodes/${TARGET_NODE}/lxc/$VMID/interfaces" 2>/dev/null)
  CONTAINER_IP=$(echo "$NETWORK_RESPONSE" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v "127.0.0.1" | head -1)
  [ -n "$CONTAINER_IP" ] && break
  sleep 2
done

[ -z "$CONTAINER_IP" ] && error "IP non trouvée"
success "IP: ${YELLOW}$CONTAINER_IP${NC}"
echo ""

# [3/4] Test SSH
info "[3/4] Test de la connexion SSH..."
ssh_test() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        root@$CONTAINER_IP 'exit' 2>/dev/null
}

if retry_command 20 3 ssh_test; then
    success "SSH opérationnel"
else
    error "SSH timeout"
fi
echo ""

# [4/4] Provisionnement Ansible
info "[4/4] Provisionnement (Ansible)..."
require_command "ansible-playbook" "Installez avec: brew install ansible"

echo -e "${YELLOW}   • Cible: ${BOLD}$CONTAINER_IP${NC}"
echo -e "${YELLOW}   • Playbook: ${BOLD}$PLAYBOOK${NC}"
echo ""

ANSIBLE_FORCE_COLOR=1 ANSIBLE_CONFIG="$ANSIBLE_CONFIG" ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  --private-key="$SSH_KEY" \
  -i "$CONTAINER_IP," \
  -u root \
  "$PLAYBOOK" || error "Échec du provisionnement"

echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         DÉPLOIEMENT RÉUSSI ! ✓         ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}🌐 Container: ${BOLD}${YELLOW}$CONTAINER_NAME${NC}"
echo -e "${CYAN}🌐 IP:        ${BOLD}${YELLOW}$CONTAINER_IP${NC}"
echo ""
