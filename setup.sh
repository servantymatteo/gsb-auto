#!/bin/bash

# Couleurs pour l'affichage
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Symboles
CHECK="✓"
CROSS="✗"
ARROW="→"
CLOCK="⏱"
ROCKET="🚀"
GEAR="⚙️"

# Démarrer le timer
START_TIME=$(date +%s)

clear
echo ""
echo "╔════════════════════════════════════════╗"
echo "║  CONFIGURATION DES CONTAINERS PROXMOX  ║"
echo "╚════════════════════════════════════════╝"
echo ""

# Charger la configuration depuis .env.local
echo -e "${CYAN}${ARROW} Vérification de la configuration...${NC}"
if [ ! -f ".env.local" ]; then
    echo -e "${RED}${CROSS} Fichier .env.local non trouvé${NC}"
    echo ""
    echo -e "${YELLOW}Créez un fichier .env.local avec vos informations d'API Proxmox :${NC}"
    echo -e "  ${BOLD}cp .env.local.example .env.local${NC}"
    echo -e "  ${BOLD}nano .env.local${NC}"
    echo ""
    exit 1
fi

echo -e "${GREEN}${CHECK} Configuration chargée avec succès${NC}"
source .env.local
echo ""

# Demander le préfixe des VMs
echo -e "${BOLD}${BLUE}━━━ Configuration de base ━━━${NC}"
echo ""
while true; do
    read -p "Préfixe des containers (ex: SIO2027) : " VM_PREFIX
    if [[ -n "$VM_PREFIX" ]]; then
        break
    fi
    echo -e "${RED}${CROSS} Le préfixe ne peut pas être vide${NC}"
done
echo ""

# Services disponibles
declare -A SERVICE_NAMES
declare -A SERVICE_PLAYBOOKS
declare -A SERVICE_DEFAULTS

SERVICE_NAMES[1]="Apache (serveur web)"
SERVICE_PLAYBOOKS[1]="install_apache.yml"
SERVICE_DEFAULTS[1]="web|2|2048|10G"

SERVICE_NAMES[2]="GLPI (gestion de parc)"
SERVICE_PLAYBOOKS[2]="install_glpi.yml"
SERVICE_DEFAULTS[2]="glpi|2|4096|20G"

SERVICE_NAMES[3]="Uptime Kuma (monitoring)"
SERVICE_PLAYBOOKS[3]="install_uptime_kuma.yml"
SERVICE_DEFAULTS[3]="monitoring|2|2048|15G"

# Afficher les services disponibles
echo -e "${BOLD}${MAGENTA}━━━ Services disponibles ━━━${NC}"
echo ""
for i in "${!SERVICE_NAMES[@]}"; do
    echo -e "  ${CYAN}[$i]${NC} ${SERVICE_NAMES[$i]}"
done
echo ""

# Demander quels services installer
while true; do
    read -p "Quels services voulez-vous installer ? (ex: 1 2 ou 1,2) : " services_input
    if [[ -n "$services_input" ]]; then
        break
    fi
    echo -e "${RED}${CROSS} Veuillez sélectionner au moins un service${NC}"
done
services_input=$(echo "$services_input" | tr ',' ' ')
echo ""

# Arrays pour stocker les VMs à créer
declare -a VM_NAMES
declare -a VM_CONFIGS

# Pour chaque service sélectionné
for service_num in $services_input; do
    if [[ -n "${SERVICE_NAMES[$service_num]}" ]]; then
        echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}${GREEN}${GEAR}  Configuration : ${SERVICE_NAMES[$service_num]}${NC}"
        echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        # Récupérer les valeurs par défaut
        IFS='|' read -r default_name default_cores default_memory default_disk <<< "${SERVICE_DEFAULTS[$service_num]}"

        # Demander les paramètres
        echo -e "${CYAN}Nom du container${NC} [${BOLD}$default_name${NC}]"
        read -p "> " vm_name
        vm_name=${vm_name:-$default_name}

        echo -e "${CYAN}CPU cores${NC} [${BOLD}$default_cores${NC}]"
        read -p "> " vm_cores
        vm_cores=${vm_cores:-$default_cores}

        echo -e "${CYAN}RAM en MB${NC} [${BOLD}$default_memory${NC}]"
        read -p "> " vm_memory
        vm_memory=${vm_memory:-$default_memory}

        echo -e "${CYAN}Taille du disque${NC} [${BOLD}$default_disk${NC}]"
        read -p "> " vm_disk
        vm_disk=${vm_disk:-$default_disk}

        # Stocker la config
        VM_NAMES+=("$vm_name")
        VM_CONFIGS+=("${vm_cores}|${vm_memory}|${vm_disk}|${SERVICE_PLAYBOOKS[$service_num]}")

        echo -e "${GREEN}${CHECK} Configuration enregistrée${NC}"
        echo ""
    fi
done

# Générer le fichier terraform.tfvars
echo -e "${BOLD}${YELLOW}━━━ Génération de la configuration ━━━${NC}"
echo -e "${CYAN}${ARROW} Création du fichier terraform.tfvars...${NC}"

cat > terraform/terraform.tfvars <<EOF
# Configuration générée automatiquement par setup.sh
# Date: $(date)

# Proxmox
pm_api_url = "$PROXMOX_API_URL"

# Authentification API Token
pm_api_token_id     = "$PROXMOX_TOKEN_ID"
pm_api_token_secret = "$PROXMOX_TOKEN_SECRET"

# Configuration de base
vm_name       = "$VM_PREFIX"
target_node   = "$TARGET_NODE"
template_name = "$TEMPLATE_NAME"
vm_storage    = "$VM_STORAGE"

# Cloud-init
ci_user     = "$CI_USER"
ci_password = "$CI_PASSWORD"
ssh_keys    = "$SSH_KEYS"

# Définition des VMs à créer
vms = {
EOF

# Ajouter chaque VM
for i in "${!VM_NAMES[@]}"; do
    vm_name="${VM_NAMES[$i]}"
    IFS='|' read -r cores memory disk playbook <<< "${VM_CONFIGS[$i]}"
    cat >> terraform/terraform.tfvars <<EOF
  "$vm_name" = {
    cores     = $cores
    memory    = $memory
    disk_size = "$disk"
    playbook  = "$playbook"
  }
EOF
done

# Fermer le fichier
echo "}" >> terraform/terraform.tfvars

echo -e "${GREEN}${CHECK} Fichier généré avec succès${NC}"
echo ""

# Calculer le temps écoulé
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║       CONFIGURATION TERMINÉE ! ${CHECK}              ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BOLD}${BLUE}📦 Containers à déployer :${NC}"
echo ""
for i in "${!VM_NAMES[@]}"; do
    vm_name="${VM_NAMES[$i]}"
    IFS='|' read -r cores memory disk playbook <<< "${VM_CONFIGS[$i]}"

    # Déterminer le type de service
    if [[ "$playbook" == "install_apache.yml" ]]; then
        SERVICE_ICON="🚀"
        SERVICE_NAME="Apache"
        SERVICE_INFO="Serveur web"
    elif [[ "$playbook" == "install_glpi.yml" ]]; then
        SERVICE_ICON="🎯"
        SERVICE_NAME="GLPI"
        SERVICE_INFO="Gestion de parc informatique"
    elif [[ "$playbook" == "install_uptime_kuma.yml" ]]; then
        SERVICE_ICON="📊"
        SERVICE_NAME="Uptime Kuma"
        SERVICE_INFO="Monitoring de services"
    else
        SERVICE_ICON="🌐"
        SERVICE_NAME="Web"
        SERVICE_INFO="Service web"
    fi

    echo -e "  ${SERVICE_ICON} ${BOLD}${SERVICE_NAME}${NC} - ${CYAN}$VM_PREFIX-$vm_name${NC}"
    echo -e "     ${SERVICE_INFO}"
    echo -e "     CPU: ${cores} cores | RAM: ${memory} MB | Disque: ${disk}"
    echo ""
done

echo -e "${CYAN}${CLOCK} Temps de configuration : ${ELAPSED}s${NC}"
echo ""

echo -e "${BOLD}${YELLOW}Lancer le déploiement maintenant ? (o/n)${NC}"
read -p "> " launch

if [[ "$launch" == "o" || "$launch" == "O" ]]; then
    echo ""
    echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${MAGENTA}${ROCKET}  DÉPLOIEMENT EN COURS...${NC}"
    echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    DEPLOY_START=$(date +%s)
    cd terraform && TF_IN_AUTOMATION=1 terraform apply --auto-approve -compact-warnings
    DEPLOY_STATUS=$?
    cd ..
    DEPLOY_END=$(date +%s)
    DEPLOY_TIME=$((DEPLOY_END - DEPLOY_START))

    echo ""
    if [ $DEPLOY_STATUS -eq 0 ]; then
        echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${GREEN}║       DÉPLOIEMENT RÉUSSI ! ${CHECK}                  ║${NC}"
        echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${CYAN}${CLOCK} Temps de déploiement : ${DEPLOY_TIME}s${NC}"
        TOTAL_TIME=$((ELAPSED + DEPLOY_TIME))
        echo -e "${CYAN}${CLOCK} Temps total : ${TOTAL_TIME}s${NC}"
        echo ""

        # Afficher les URLs d'accès aux services
        echo -e "${BOLD}${BLUE}━━━ Services déployés ━━━${NC}"
        echo ""

        for i in "${!VM_NAMES[@]}"; do
            vm_name="${VM_NAMES[$i]}"
            IFS='|' read -r cores memory disk playbook <<< "${VM_CONFIGS[$i]}"

            # Récupérer l'IP du container depuis Terraform
            cd terraform
            CONTAINER_IP=$(terraform state show "proxmox_lxc.container[\"$vm_name\"]" 2>/dev/null | grep "ipv4_addresses" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
            cd ..

            # Déterminer l'URL en fonction du service
            if [[ "$playbook" == "install_apache.yml" ]]; then
                SERVICE_URL="http://${CONTAINER_IP}"
                SERVICE_ICON="🚀"
                SERVICE_NAME="Apache"
            elif [[ "$playbook" == "install_glpi.yml" ]]; then
                SERVICE_URL="http://${CONTAINER_IP}/glpi"
                SERVICE_ICON="🎯"
                SERVICE_NAME="GLPI"
                CREDENTIALS="${YELLOW}glpi / glpi${NC}"
            elif [[ "$playbook" == "install_uptime_kuma.yml" ]]; then
                SERVICE_URL="http://${CONTAINER_IP}:3001"
                SERVICE_ICON="📊"
                SERVICE_NAME="Uptime Kuma"
            else
                SERVICE_URL="http://${CONTAINER_IP}"
                SERVICE_ICON="🌐"
                SERVICE_NAME="Web"
            fi

            echo -e "  ${SERVICE_ICON} ${BOLD}${SERVICE_NAME}${NC} - ${CYAN}$VM_PREFIX-$vm_name${NC}"
            echo -e "     ${BLUE}${SERVICE_URL}${NC}"

            if [[ -n "$CREDENTIALS" ]]; then
                echo -e "     👤 ${CREDENTIALS}"
                CREDENTIALS=""
            fi

            echo ""
        done
    else
        echo -e "${BOLD}${RED}╔════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${RED}║       DÉPLOIEMENT ÉCHOUÉ ${CROSS}                    ║${NC}"
        echo -e "${BOLD}${RED}╚════════════════════════════════════════════════╝${NC}"
    fi
    echo ""
else
    echo ""
    echo -e "${YELLOW}Pour lancer le déploiement plus tard :${NC}"
    echo -e "  ${BOLD}cd terraform && terraform apply --auto-approve${NC}"
    echo ""
fi
