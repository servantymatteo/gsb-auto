#!/bin/bash
set -e

# Charger les fonctions communes
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"

print_header "UPLOAD FICHIER CLOUD-INIT SUR PROXMOX"

# Charger .env.local
ENV_FILE="$PROJECT_ROOT/.env.local"
[ ! -f "$ENV_FILE" ] && error ".env.local non trouvé"
source "$ENV_FILE"

# Fichiers à uploader
CLOUD_INIT_FILE="$PROJECT_ROOT/terraform/cloud-init/windows-firstboot-adds.yml"

# Vérifier que le fichier existe
if [ ! -f "$CLOUD_INIT_FILE" ]; then
    error "Fichier cloud-init non trouvé: $CLOUD_INIT_FILE"
fi

info "Fichier à uploader: windows-firstboot-adds.yml"
echo ""

# Extraire l'IP de Proxmox de l'URL de l'API
PROXMOX_HOST=$(echo "$PROXMOX_API_URL" | sed -E 's|https?://([^:/]+).*|\1|')

info "Upload vers Proxmox: $PROXMOX_HOST"
info "Destination: /var/lib/vz/snippets/"
echo ""

# Méthode 1: Upload via SCP
if command -v scp &> /dev/null; then
    info "Méthode: SCP"
    echo ""

    warning "Authentification SSH requise"
    echo ""

    # Upload du fichier
    scp "$CLOUD_INIT_FILE" "root@$PROXMOX_HOST:/var/lib/vz/snippets/windows-firstboot-adds.yml"

    if [ $? -eq 0 ]; then
        echo ""
        success "Fichier uploadé avec succès !"
        echo ""

        # Vérifier les permissions
        ssh "root@$PROXMOX_HOST" "chmod 644 /var/lib/vz/snippets/windows-firstboot-adds.yml"

        success "Permissions configurées"
        echo ""
    else
        error "Échec de l'upload SCP"
    fi
else
    error "SCP non disponible. Installez openssh-client"
fi

echo "╔════════════════════════════════════════╗"
echo "║    UPLOAD TERMINÉ ! ✓                  ║"
echo "╚════════════════════════════════════════╝"
echo ""
echo "Le fichier cloud-init est prêt à être utilisé par Terraform."
echo ""
echo "Prochaine étape:"
echo "  1. Créez le template Windows (voir docs/windows-template-setup.md)"
echo "  2. Lancez terraform apply"
echo ""
