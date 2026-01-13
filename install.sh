#!/bin/bash

# ============================================
# Script d'installation auto_gsb sur Proxmox
# Installation en une commande depuis GitHub
# ============================================

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Fonctions
success() { echo -e "${GREEN}✓ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}" >&2; exit "${2:-1}"; }
info() { echo -e "${CYAN}→ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠  $1${NC}"; }

clear
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║    AUTO GSB - Installation sur Proxmox        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
echo ""

# Vérifier qu'on est sur Proxmox
if [ ! -f "/etc/pve/.version" ]; then
    error "Ce script doit être exécuté sur le serveur Proxmox!"
fi

success "Exécution sur le serveur Proxmox détectée"

# Variables
INSTALL_DIR="/root/auto_gsb"
GITHUB_REPO="https://github.com/VOTRE_USERNAME/auto_gsb"  # À MODIFIER

# Vérifier que git est installé
if ! command -v git &> /dev/null; then
    info "Installation de git..."
    apt update && apt install -y git
fi

# Vérifier que Terraform est installé
if ! command -v terraform &> /dev/null; then
    warning "Terraform n'est pas installé"
    read -p "Voulez-vous installer Terraform? (o/N): " INSTALL_TF
    if [[ "$INSTALL_TF" =~ ^[oOyY]$ ]]; then
        info "Installation de Terraform..."
        wget -q https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip
        apt install -y unzip
        unzip -q terraform_1.7.0_linux_amd64.zip
        mv terraform /usr/local/bin/
        chmod +x /usr/local/bin/terraform
        rm terraform_1.7.0_linux_amd64.zip
        success "Terraform installé: $(terraform version | head -1)"
    else
        error "Terraform est requis pour continuer"
    fi
else
    success "Terraform déjà installé: $(terraform version | head -1)"
fi

# Vérifier qu'Ansible est installé
if ! command -v ansible &> /dev/null; then
    warning "Ansible n'est pas installé"
    read -p "Voulez-vous installer Ansible? (o/N): " INSTALL_ANS
    if [[ "$INSTALL_ANS" =~ ^[oOyY]$ ]]; then
        info "Installation d'Ansible..."
        apt update && apt install -y ansible python3-pip
        success "Ansible installé: $(ansible --version | head -1)"
    else
        error "Ansible est requis pour continuer"
    fi
else
    success "Ansible déjà installé: $(ansible --version | head -1)"
fi

# Cloner ou mettre à jour le repository
if [ -d "$INSTALL_DIR" ]; then
    warning "Le répertoire $INSTALL_DIR existe déjà"
    read -p "Voulez-vous le mettre à jour? (o/N): " UPDATE_REPO
    if [[ "$UPDATE_REPO" =~ ^[oOyY]$ ]]; then
        info "Mise à jour du repository..."
        cd "$INSTALL_DIR"
        git pull
        success "Repository mis à jour"
    fi
else
    info "Clonage du repository..."
    git clone "$GITHUB_REPO" "$INSTALL_DIR"
    success "Repository cloné dans $INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# Configurer .env.local
if [ ! -f ".env.local" ]; then
    info "Configuration de .env.local..."

    # Demander le nom du node
    read -p "Nom du node Proxmox (défaut: proxmox): " NODE_NAME
    NODE_NAME="${NODE_NAME:-proxmox}"

    # Demander le mot de passe root
    read -sp "Mot de passe root Proxmox: " ROOT_PASSWORD
    echo ""

    # Créer .env.local
    cat > .env.local <<EOF
# Configuration générée par install.sh
# Date: $(date)

# Node Proxmox
TARGET_NODE=${NODE_NAME}

# Template LXC Debian
TEMPLATE_NAME=debian-12-standard_12.12-1_amd64.tar.zst

# Stockage
VM_STORAGE=local-lvm

# Clé SSH (générez une clé avec: ssh-keygen -t ed25519)
SSH_KEYS=""

# Credentials par défaut des containers
CI_USER=sio2027
CI_PASSWORD=Formation13@

# Authentification Proxmox locale
PM_USER=root@pam
PM_PASSWORD=${ROOT_PASSWORD}

# Configuration Windows (optionnel)
WINDOWS_TEMPLATE_ID=WSERVER-TEMPLATE
WINDOWS_ADMIN_PASSWORD=Admin123@
EOF

    success ".env.local créé"
    warning "Pensez à ajouter votre clé SSH publique dans .env.local"
else
    success ".env.local existe déjà"
fi

# Vérifier le template Debian
info "Vérification du template Debian..."
if ! pveam list local | grep -q "debian-12-standard"; then
    warning "Template Debian 12 non trouvé"
    read -p "Voulez-vous le télécharger? (o/N): " DOWNLOAD_TPL
    if [[ "$DOWNLOAD_TPL" =~ ^[oOyY]$ ]]; then
        info "Téléchargement du template (cela peut prendre quelques minutes)..."
        pveam download local debian-12-standard_12.12-1_amd64.tar.zst
        success "Template téléchargé"
    fi
else
    success "Template Debian 12 trouvé"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         INSTALLATION TERMINÉE ✓                ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Prochaines étapes:${NC}"
echo ""
echo "1. Configurer votre clé SSH:"
echo "   ${YELLOW}nano $INSTALL_DIR/.env.local${NC}"
echo ""
echo "2. Lancer le déploiement:"
echo "   ${YELLOW}cd $INSTALL_DIR${NC}"
echo "   ${YELLOW}./deploy_local.sh${NC}"
echo ""
echo "3. Documentation complète:"
echo "   ${YELLOW}cat $INSTALL_DIR/DEPLOY_LOCAL.md${NC}"
echo ""
