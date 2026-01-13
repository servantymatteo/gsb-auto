#!/bin/bash
set -e

# Charger les fonctions communes
source "$(dirname "$0")/common.sh"

print_header "PRÉPARATION ISO AUTOUNATTEND"

# Charger .env.local
ENV_FILE="$PROJECT_ROOT/.env.local"
[ ! -f "$ENV_FILE" ] && error ".env.local non trouvé"
source "$ENV_FILE"

# [1/3] Créer l'ISO
info "[1/3] Création de l'ISO autounattend.xml..."
"$(dirname "$0")/create_autounattend_iso.sh"

ISO_FILE="$TERRAFORM_DIR/autounattend.iso"
[ ! -f "$ISO_FILE" ] && error "Échec de la création de l'ISO"
success "ISO créé"
echo ""

# [2/3] Upload via API Proxmox
info "[2/3] Upload sur Proxmox..."

API_BASE_URL="${PROXMOX_API_URL%/api2/json}"
TARGET_NODE="${TARGET_NODE:-proxmox}"

UPLOAD_RESPONSE=$(curl -k -s -w "\n%{http_code}" \
    -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
    -X POST "${API_BASE_URL}/api2/json/nodes/${TARGET_NODE}/storage/local/upload" \
    -F "content=iso" \
    -F "filename=@${ISO_FILE}")

HTTP_CODE=$(echo "$UPLOAD_RESPONSE" | tail -n1)
BODY=$(echo "$UPLOAD_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    success "ISO uploadé sur Proxmox"
    echo ""
else
    echo -e "${RED}✗ Erreur upload (HTTP $HTTP_CODE)${NC}"
    echo "$BODY\n"
    warning "Upload manuel requis:"
    echo -e "   ${GREEN}scp $ISO_FILE root@${TARGET_NODE}:/var/lib/vz/template/iso/${NC}\n"
    exit 1
fi

# [3/3] Vérification
info "[3/3] Vérification..."

STORAGE_RESPONSE=$(curl -k -s \
    -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
    "${API_BASE_URL}/api2/json/nodes/${TARGET_NODE}/storage/local/content")

if echo "$STORAGE_RESPONSE" | grep -q "autounattend.iso"; then
    success "ISO disponible dans Proxmox\n"
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    PRÉPARATION TERMINÉE ! ✓            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    echo -e "${BLUE}L'ISO est prêt. Lancez ./setup.sh${NC}\n"
else
    warning "ISO non détecté. Vérifiez l'interface Proxmox\n"
fi
