#!/bin/bash

# ============================================
# Script de déploiement LOCAL sur Proxmox
# Déploie uniquement les containers Linux (pas de Windows)
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

# Chemin du script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  DÉPLOIEMENT LOCAL - CONTAINERS LINUX${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Vérifier qu'on est sur Proxmox
if [ ! -f "/etc/pve/.version" ]; then
    error "Ce script doit être exécuté sur le serveur Proxmox!"
fi

success "Exécution sur le serveur Proxmox détectée"

# Charger les variables d'environnement
if [ ! -f .env.local ]; then
    error "Fichier .env.local introuvable. Copiez .env.local.example et configurez-le."
fi

info "Chargement des variables d'environnement..."
source .env.local
success "Variables chargées"

# Menu de sélection des services
echo ""
echo -e "${CYAN}Services disponibles:${NC}"
echo "  1) Apache + PHP"
echo "  2) MySQL / MariaDB"
echo "  3) Uptime Kuma (Monitoring)"
echo "  4) AdGuard Home (DNS + Ad Blocker)"
echo "  5) Tous les services ci-dessus"
echo "  0) Quitter"
echo ""
read -p "Votre choix: " CHOICE

case $CHOICE in
    1)
        SERVICE_NAME="apache"
        PLAYBOOK="install_apache.yml"
        VM_CORES=2
        VM_MEMORY=2048
        VM_DISK="10G"
        ;;
    2)
        SERVICE_NAME="mysql"
        PLAYBOOK="install_mysql.yml"
        VM_CORES=2
        VM_MEMORY=2048
        VM_DISK="15G"
        ;;
    3)
        SERVICE_NAME="monitoring"
        PLAYBOOK="install_uptime_kuma.yml"
        VM_CORES=2
        VM_MEMORY=2048
        VM_DISK="15G"
        ;;
    4)
        SERVICE_NAME="adguard"
        PLAYBOOK="install_adguard.yml"
        VM_CORES=1
        VM_MEMORY=1024
        VM_DISK="8G"
        ;;
    5)
        SERVICE_NAME="all"
        ;;
    0)
        info "Annulé par l'utilisateur"
        exit 0
        ;;
    *)
        error "Choix invalide"
        ;;
esac

# Configuration du nom de VM
echo ""
read -p "Nom de base pour les VMs (défaut: GSB): " VM_NAME_INPUT
VM_NAME="${VM_NAME_INPUT:-GSB}"

# Créer le fichier terraform.tfvars
info "Génération de la configuration Terraform..."

cd terraform

cat > terraform.tfvars <<EOF
# Configuration générée automatiquement par deploy_local.sh
# Date: $(date)

# Proxmox (localhost car exécuté sur Proxmox)
pm_api_url = "https://localhost:8006/api2/json"

# Authentification par mot de passe (local)
pm_user     = "${PM_USER:-root@pam}"
pm_password = "${PM_PASSWORD}"

# Configuration de base
vm_name       = "$VM_NAME"
target_node   = "${TARGET_NODE}"
template_name = "${TEMPLATE_NAME}"
vm_storage    = "${VM_STORAGE}"

# Cloud-init
ci_user     = "${CI_USER}"
ci_password = "${CI_PASSWORD}"
ssh_keys    = "${SSH_KEYS}"

# Définition des VMs à créer
vms = {
EOF

if [ "$SERVICE_NAME" = "all" ]; then
    cat >> terraform.tfvars <<EOF
  "apache" = {
    cores     = 2
    memory    = 2048
    disk_size = "10G"
    playbook  = "install_apache.yml"
  }
  "mysql" = {
    cores     = 2
    memory    = 2048
    disk_size = "15G"
    playbook  = "install_mysql.yml"
  }
  "monitoring" = {
    cores     = 2
    memory    = 2048
    disk_size = "15G"
    playbook  = "install_uptime_kuma.yml"
  }
  "adguard" = {
    cores     = 1
    memory    = 1024
    disk_size = "8G"
    playbook  = "install_adguard.yml"
  }
EOF
else
    cat >> terraform.tfvars <<EOF
  "${SERVICE_NAME}" = {
    cores     = ${VM_CORES}
    memory    = ${VM_MEMORY}
    disk_size = "${VM_DISK}"
    playbook  = "${PLAYBOOK}"
  }
EOF
fi

cat >> terraform.tfvars <<EOF
}
EOF

success "Configuration générée: terraform/terraform.tfvars"

# Afficher la configuration
echo ""
info "Configuration:"
cat terraform.tfvars
echo ""

# Demander confirmation
read -p "Continuer avec cette configuration? (o/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[oOyY]$ ]]; then
    error "Déploiement annulé"
fi

# Initialiser Terraform si nécessaire
if [ ! -d ".terraform" ]; then
    info "Initialisation de Terraform..."
    terraform init || error "Échec de l'initialisation Terraform"
    success "Terraform initialisé"
fi

# Planifier
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  PLANIFICATION${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

terraform plan || error "Échec de la planification"

# Demander confirmation pour appliquer
echo ""
read -p "Appliquer les changements? (o/N): " APPLY_CONFIRM
if [[ ! "$APPLY_CONFIRM" =~ ^[oOyY]$ ]]; then
    error "Déploiement annulé"
fi

# Déployer
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  DÉPLOIEMENT EN COURS...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if terraform apply -auto-approve; then
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       DÉPLOIEMENT RÉUSSI ✓                    ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
    echo ""

    # Afficher les IPs
    info "Récupération des adresses IP..."
    terraform output

else
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║       DÉPLOIEMENT ÉCHOUÉ ✗                    ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════╝${NC}"
    exit 1
fi
