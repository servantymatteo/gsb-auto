#!/bin/bash

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

success() { echo -e "${GREEN}✓ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}" >&2; exit "${2:-1}"; }
info() { echo -e "${CYAN}→ $1${NC}"; }

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
GITHUB_REPO="https://github.com/servantymatteo/gsb-auto.git"
LXC_TEMPLATE_FILENAME="debian-12-standard_12.12-1_amd64.tar.zst"
LXC_TEMPLATE="/var/lib/vz/template/cache/$LXC_TEMPLATE_FILENAME"
LXC_TEMPLATE_URL="http://download.proxmox.com/images/system/$LXC_TEMPLATE_FILENAME"

# === 1. Installation de Terraform ===
if ! command -v terraform &> /dev/null; then
    info "Installation de Terraform..."
    wget -q https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip
    apt install -y unzip
    unzip -q terraform_1.7.0_linux_amd64.zip
    mv terraform /usr/local/bin/
    chmod +x /usr/local/bin/terraform
    rm terraform_1.7.0_linux_amd64.zip
    success "Terraform installé: $(terraform version | head -1)"
else
    success "Terraform déjà installé"
fi

# === 2. Installation d'Ansible ===
if ! command -v ansible &> /dev/null; then
    info "Installation d'Ansible..."
    apt update && apt install -y ansible python3-pip
    success "Ansible installé"
else
    success "Ansible déjà installé"
fi

# === 3. Installation de git ===
if ! command -v git &> /dev/null; then
    info "Installation de git..."
    apt install -y git
fi

# === 4. Téléchargement du template LXC Debian ===
if [ ! -f "$LXC_TEMPLATE" ]; then
    info "Téléchargement du template Debian 12..."
    wget -O "$LXC_TEMPLATE" "$LXC_TEMPLATE_URL"
    success "Template téléchargé"
else
    success "Template Debian 12 déjà présent"
fi

# === 5. Clonage du repository ===
if [ -d "$INSTALL_DIR" ]; then
    info "Le répertoire $INSTALL_DIR existe déjà, mise à jour..."
    cd "$INSTALL_DIR"
    git pull
else
    info "Clonage du repository depuis GitHub..."
    git clone -b local "$GITHUB_REPO" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
success "Projet récupéré"

# === 6. Configuration ===
info "Configuration de l'environnement..."

# Demander le nom du node
read -p "Nom du node Proxmox (défaut: $(hostname)): " NODE_NAME
NODE_NAME="${NODE_NAME:-$(hostname)}"

# Demander le mot de passe root
read -sp "Mot de passe root Proxmox: " ROOT_PASSWORD
echo ""

# Générer clé SSH si elle n'existe pas
SSH_KEY_PATH="/root/.ssh/id_ed25519"
if [ ! -f "$SSH_KEY_PATH" ]; then
    info "Génération d'une clé SSH..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N ""
    success "Clé SSH générée"
fi

SSH_PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")

# Créer .env.local
cat > .env.local <<EOF
# Configuration générée par install.sh
# Date: $(date)

# Node Proxmox
TARGET_NODE=${NODE_NAME}

# Template LXC Debian
TEMPLATE_NAME=${LXC_TEMPLATE_FILENAME}

# Stockage
VM_STORAGE=local-lvm

# Clé SSH
SSH_KEYS="${SSH_PUB_KEY}"

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

# === 7. Lancement du déploiement ===
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         INSTALLATION TERMINÉE ✓                ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Pour déployer des containers:${NC}"
echo "   ${YELLOW}cd $INSTALL_DIR${NC}"
echo "   ${YELLOW}./deploy_local.sh${NC}"
echo ""
