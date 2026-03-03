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

error_exit() {
    echo -e "${RED}${CROSS} $1${NC}" >&2
    exit 1
}

require_command() {
    local cmd="$1"
    local hint="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error_exit "$cmd n'est pas installé. $hint"
    fi
}

require_env_var() {
    local var_name="$1"
    if [ -z "${!var_name:-}" ]; then
        error_exit "Variable manquante dans .env.local: $var_name"
    fi
}

windows_template_exists() {
    local template_id="$1"
    local api_base_url="${PROXMOX_API_URL%/api2/json}"
    local response=""

    response=$(curl -k -s -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
      "${api_base_url}/api2/json/cluster/resources?type=vm" 2>/dev/null || true)

    [ -z "$response" ] && return 1

    # Match par nom OU par VMID
    echo "$response" | grep -qE "\"name\":\"${template_id}\"|\"vmid\":${template_id}([,}])"
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_valid_disk_size() {
    [[ "$1" =~ ^[1-9][0-9]*[Gg]$ ]]
}

default_netbios_from_domain() {
    local domain="$1"
    local first_label="${domain%%.*}"
    echo "${first_label^^}"
}

# Démarrer le timer
START_TIME=$(date +%s)

clear
echo ""
echo "╔════════════════════════════════════════╗"
echo "║      CONFIGURATION INFRA PROXMOX       ║"
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

# Préflight outils requis
require_command "terraform" "Installe-le via ./install.sh"
require_command "curl" "Installe curl (apt install curl)"
require_command "ansible-playbook" "Installe Ansible via ./install.sh"

# Vérification des variables minimales
require_env_var "PROXMOX_API_URL"
require_env_var "PROXMOX_TOKEN_ID"
require_env_var "PROXMOX_TOKEN_SECRET"
require_env_var "TARGET_NODE"
require_env_var "TEMPLATE_NAME"
require_env_var "VM_STORAGE"
require_env_var "CI_USER"
require_env_var "CI_PASSWORD"

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

DEFAULT_VM_NETWORK_BRIDGE="${VM_NETWORK_BRIDGE:-vmbr0}"
echo -e "${CYAN}Bridge réseau Proxmox${NC} [${BOLD}$DEFAULT_VM_NETWORK_BRIDGE${NC}]"
read -p "> " VM_NETWORK_BRIDGE_SELECTED
VM_NETWORK_BRIDGE_SELECTED="${VM_NETWORK_BRIDGE_SELECTED:-$DEFAULT_VM_NETWORK_BRIDGE}"
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

SERVICE_NAMES[4]="AdGuard Home (bloqueur DNS)"
SERVICE_PLAYBOOKS[4]="install_adguard.yml"
SERVICE_DEFAULTS[4]="adguard|1|1024|8G"

SERVICE_NAMES[5]="Active Directory (contrôleur de domaine Windows)"
SERVICE_PLAYBOOKS[5]="install_ad_ds.yml"
SERVICE_DEFAULTS[5]="dc|4|4096|60G"

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

# Vérifier et dédupliquer la sélection des services
declare -A SEEN_SERVICES
declare -a SELECTED_SERVICES
for service_num in $services_input; do
    if [[ -z "${SERVICE_NAMES[$service_num]}" ]]; then
        error_exit "Service invalide: '$service_num'. Choix valides: 1 2 3 4 5"
    fi
    if [[ -z "${SEEN_SERVICES[$service_num]}" ]]; then
        SEEN_SERVICES[$service_num]=1
        SELECTED_SERVICES+=("$service_num")
    fi
done

if [ ${#SELECTED_SERVICES[@]} -eq 0 ]; then
    error_exit "Aucun service valide sélectionné."
fi

for service_num in "${SELECTED_SERVICES[@]}"; do
    if [ "$service_num" = "5" ]; then
        require_command "pwsh" "PowerShell est requis pour Active Directory (Windows)."

        WINDOWS_TEMPLATE_TO_USE="${WINDOWS_TEMPLATE_ID:-WSERVER-TEMPLATE}"
        if ! windows_template_exists "$WINDOWS_TEMPLATE_TO_USE"; then
            echo ""
            echo -e "${YELLOW}${ARROW} Template Windows introuvable: ${BOLD}${WINDOWS_TEMPLATE_TO_USE}${NC}"
            echo -e "${YELLOW}Choisis une option:${NC}"
            echo -e "  ${CYAN}[1]${NC} Créer le template maintenant (auto)"
            echo -e "  ${CYAN}[2]${NC} Continuer sans Active Directory"
            echo -e "  ${CYAN}[3]${NC} Arrêter pour corriger le template"
            read -p "> " MISSING_TEMPLATE_ACTION
            MISSING_TEMPLATE_ACTION="${MISSING_TEMPLATE_ACTION:-3}"

            if [ "$MISSING_TEMPLATE_ACTION" = "1" ]; then
                if [ ! -x "./scripts/create_windows_template.sh" ]; then
                    error_exit "Script introuvable: scripts/create_windows_template.sh"
                fi
                ./scripts/create_windows_template.sh

                # Recharger la valeur éventuelle de WINDOWS_TEMPLATE_ID
                source .env.local
                WINDOWS_TEMPLATE_TO_USE="${WINDOWS_TEMPLATE_ID:-WSERVER-TEMPLATE}"
                if ! windows_template_exists "$WINDOWS_TEMPLATE_TO_USE"; then
                    error_exit "Template non détecté après création auto. Vérifie la VM source/sysprep."
                fi
                echo -e "${GREEN}${CHECK} Template Windows disponible: ${WINDOWS_TEMPLATE_TO_USE}${NC}"
            elif [ "$MISSING_TEMPLATE_ACTION" = "2" ]; then
                # Retirer AD de la sélection
                FILTERED_SERVICES=()
                for s in "${SELECTED_SERVICES[@]}"; do
                    [ "$s" != "5" ] && FILTERED_SERVICES+=("$s")
                done
                SELECTED_SERVICES=("${FILTERED_SERVICES[@]}")
                echo -e "${YELLOW}${ARROW} Active Directory retiré de la sélection.${NC}"
            else
                error_exit "Déploiement annulé. Configure d'abord WINDOWS_TEMPLATE_ID dans .env.local."
            fi
        fi
    fi
done

if [ ${#SELECTED_SERVICES[@]} -eq 0 ]; then
    error_exit "Aucun service à déployer après vérifications."
fi

AD_SELECTED=0
for service_num in "${SELECTED_SERVICES[@]}"; do
    if [ "$service_num" = "5" ]; then
        AD_SELECTED=1
        break
    fi
done

if [ "$AD_SELECTED" -eq 1 ]; then
    echo -e "${BOLD}${BLUE}━━━ Configuration Active Directory ━━━${NC}"
    echo ""

    DEFAULT_AD_DOMAIN_NAME="${AD_DOMAIN_NAME:-gsb.local}"
    DEFAULT_AD_DOMAIN_NETBIOS="${AD_DOMAIN_NETBIOS:-$(default_netbios_from_domain "$DEFAULT_AD_DOMAIN_NAME")}"
    DEFAULT_AD_SAFE_MODE_PASSWORD="${AD_SAFE_MODE_PASSWORD:-SafeMode123@}"
    DEFAULT_AD_ADMIN_PASSWORD="${AD_ADMIN_PASSWORD:-${WINDOWS_ADMIN_PASSWORD:-Admin123@}}"
    DEFAULT_AD_DEFAULT_USER_PASSWORD="${AD_DEFAULT_USER_PASSWORD:-User123@}"
    DEFAULT_AD_DNS_FORWARDERS="${AD_DNS_FORWARDERS:-8.8.8.8,8.8.4.4}"
    DEFAULT_AD_USERS_OU_NAME="${AD_USERS_OU_NAME:-Utilisateurs_GSB}"
    DEFAULT_AD_OUS="${AD_OUS:-Utilisateurs_GSB,Ordinateurs_GSB,Serveurs_GSB}"

    echo -e "${CYAN}Nom du domaine AD${NC} [${BOLD}$DEFAULT_AD_DOMAIN_NAME${NC}]"
    read -p "> " AD_DOMAIN_NAME
    AD_DOMAIN_NAME="${AD_DOMAIN_NAME:-$DEFAULT_AD_DOMAIN_NAME}"

    echo -e "${CYAN}Nom NetBIOS${NC} [${BOLD}$DEFAULT_AD_DOMAIN_NETBIOS${NC}]"
    read -p "> " AD_DOMAIN_NETBIOS
    AD_DOMAIN_NETBIOS="${AD_DOMAIN_NETBIOS:-$DEFAULT_AD_DOMAIN_NETBIOS}"

    echo -e "${CYAN}Mot de passe Safe Mode${NC} [${BOLD}$DEFAULT_AD_SAFE_MODE_PASSWORD${NC}]"
    read -p "> " AD_SAFE_MODE_PASSWORD
    AD_SAFE_MODE_PASSWORD="${AD_SAFE_MODE_PASSWORD:-$DEFAULT_AD_SAFE_MODE_PASSWORD}"

    echo -e "${CYAN}Mot de passe admin domaine${NC} [${BOLD}$DEFAULT_AD_ADMIN_PASSWORD${NC}]"
    read -p "> " AD_ADMIN_PASSWORD
    AD_ADMIN_PASSWORD="${AD_ADMIN_PASSWORD:-$DEFAULT_AD_ADMIN_PASSWORD}"

    echo -e "${CYAN}Mot de passe utilisateurs par défaut${NC} [${BOLD}$DEFAULT_AD_DEFAULT_USER_PASSWORD${NC}]"
    read -p "> " AD_DEFAULT_USER_PASSWORD
    AD_DEFAULT_USER_PASSWORD="${AD_DEFAULT_USER_PASSWORD:-$DEFAULT_AD_DEFAULT_USER_PASSWORD}"

    echo -e "${CYAN}DNS forwarders (CSV)${NC} [${BOLD}$DEFAULT_AD_DNS_FORWARDERS${NC}]"
    read -p "> " AD_DNS_FORWARDERS
    AD_DNS_FORWARDERS="${AD_DNS_FORWARDERS:-$DEFAULT_AD_DNS_FORWARDERS}"

    echo -e "${CYAN}OU utilisateurs${NC} [${BOLD}$DEFAULT_AD_USERS_OU_NAME${NC}]"
    read -p "> " AD_USERS_OU_NAME
    AD_USERS_OU_NAME="${AD_USERS_OU_NAME:-$DEFAULT_AD_USERS_OU_NAME}"

    echo -e "${CYAN}Liste des OUs (CSV)${NC} [${BOLD}$DEFAULT_AD_OUS${NC}]"
    read -p "> " AD_OUS
    AD_OUS="${AD_OUS:-$DEFAULT_AD_OUS}"

    mkdir -p ansible/vars
    {
        echo "domain_name: \"$AD_DOMAIN_NAME\""
        echo "domain_netbios: \"$AD_DOMAIN_NETBIOS\""
        echo "safe_mode_password: \"$AD_SAFE_MODE_PASSWORD\""
        echo "admin_password: \"$AD_ADMIN_PASSWORD\""
        echo "default_user_password: \"$AD_DEFAULT_USER_PASSWORD\""
        echo "users_ou_name: \"$AD_USERS_OU_NAME\""
        echo "ad_admin_group: \"Admins_GSB\""
        echo "ad_admin_user:"
        echo "  name: \"admin.gsb\""
        echo "  firstname: \"Admin\""
        echo "  surname: \"GSB\""
        echo "dns_forwarders:"
        IFS=',' read -ra _dns_arr <<< "$AD_DNS_FORWARDERS"
        for dns_ip in "${_dns_arr[@]}"; do
            dns_ip_trimmed="$(echo "$dns_ip" | xargs)"
            [ -n "$dns_ip_trimmed" ] && echo "  - \"$dns_ip_trimmed\""
        done
        echo "ad_ous:"
        IFS=',' read -ra _ou_arr <<< "$AD_OUS"
        for ou_name in "${_ou_arr[@]}"; do
            ou_name_trimmed="$(echo "$ou_name" | xargs)"
            [ -n "$ou_name_trimmed" ] && echo "  - \"$ou_name_trimmed\""
        done
        echo "ad_test_users:"
        echo "  - name: \"user1.gsb\""
        echo "    firstname: \"Utilisateur\""
        echo "    surname: \"Un\""
        echo "  - name: \"user2.gsb\""
        echo "    firstname: \"Utilisateur\""
        echo "    surname: \"Deux\""
        echo "  - name: \"user3.gsb\""
        echo "    firstname: \"Utilisateur\""
        echo "    surname: \"Trois\""
    } > ansible/vars/ad_ds.yml

    echo -e "${GREEN}${CHECK} Fichier AD généré: ansible/vars/ad_ds.yml${NC}"
    echo ""
fi

# Arrays pour stocker les VMs à créer
declare -a VM_NAMES
declare -a VM_CONFIGS

# Pour chaque service sélectionné
for service_num in "${SELECTED_SERVICES[@]}"; do
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}${GEAR}  Configuration : ${SERVICE_NAMES[$service_num]}${NC}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Récupérer les valeurs par défaut
    IFS='|' read -r default_name default_cores default_memory default_disk <<< "${SERVICE_DEFAULTS[$service_num]}"

    # Demander les paramètres
    echo -e "${CYAN}Nom du container/VM${NC} [${BOLD}$default_name${NC}]"
    read -p "> " vm_name
    vm_name=${vm_name:-$default_name}

    if [[ ! "$vm_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        error_exit "Nom invalide '$vm_name'. Utilise lettres/chiffres/tirets."
    fi

    echo -e "${CYAN}CPU cores${NC} [${BOLD}$default_cores${NC}]"
    read -p "> " vm_cores
    vm_cores=${vm_cores:-$default_cores}
    is_positive_integer "$vm_cores" || error_exit "CPU invalide pour $vm_name: '$vm_cores'"

    echo -e "${CYAN}RAM en MB${NC} [${BOLD}$default_memory${NC}]"
    read -p "> " vm_memory
    vm_memory=${vm_memory:-$default_memory}
    is_positive_integer "$vm_memory" || error_exit "RAM invalide pour $vm_name: '$vm_memory'"

    echo -e "${CYAN}Taille du disque${NC} [${BOLD}$default_disk${NC}]"
    read -p "> " vm_disk
    vm_disk=${vm_disk:-$default_disk}
    is_valid_disk_size "$vm_disk" || error_exit "Disque invalide pour $vm_name: '$vm_disk' (ex: 10G)"

    playbook="${SERVICE_PLAYBOOKS[$service_num]}"
    if [ ! -f "ansible/playbooks/$playbook" ]; then
        error_exit "Playbook introuvable: ansible/playbooks/$playbook"
    fi

    # Empêcher les doublons de nom
    for existing_name in "${VM_NAMES[@]}"; do
        if [ "$existing_name" = "$vm_name" ]; then
            error_exit "Nom dupliqué détecté: '$vm_name'"
        fi
    done

    # Stocker la config
    VM_NAMES+=("$vm_name")
    VM_CONFIGS+=("${vm_cores}|${vm_memory}|${vm_disk}|${playbook}")

    echo -e "${GREEN}${CHECK} Configuration enregistrée${NC}"
    echo ""
done

# Générer le fichier terraform.tfvars
echo -e "${BOLD}${YELLOW}━━━ Génération de la configuration ━━━${NC}"
echo -e "${CYAN}${ARROW} Création du fichier terraform.tfvars...${NC}"
SSH_KEYS_VALUE="${SSH_KEYS:-}"

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
vm_network_bridge = "$VM_NETWORK_BRIDGE_SELECTED"

# Cloud-init
ci_user     = "$CI_USER"
ci_password = "$CI_PASSWORD"
ssh_keys    = "$SSH_KEYS_VALUE"

# Configuration Windows
windows_template_id    = "${WINDOWS_TEMPLATE_ID:-WSERVER-TEMPLATE}"
windows_admin_password = "${WINDOWS_ADMIN_PASSWORD:-Admin123@}"

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
    elif [[ "$playbook" == "install_adguard.yml" ]]; then
        SERVICE_ICON="🛡️"
        SERVICE_NAME="AdGuard Home"
        SERVICE_INFO="Bloqueur de publicités DNS"
    elif [[ "$playbook" == "install_ad_ds.yml" ]]; then
        SERVICE_ICON="🏢"
        SERVICE_NAME="Active Directory"
        SERVICE_INFO="Contrôleur de domaine gsb.local (Windows Server)"
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
    if [ ! -d "terraform/.terraform" ]; then
        echo -e "${CYAN}${ARROW} Initialisation Terraform...${NC}"
        (cd terraform && terraform init -input=false -compact-warnings)
    fi
    (cd terraform && TF_IN_AUTOMATION=1 terraform apply --auto-approve -compact-warnings)
    DEPLOY_STATUS=$?
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

            # Récupérer l'IP depuis l'API Proxmox (LXC ou QEMU selon le type)
            FULL_CONTAINER_NAME="$VM_PREFIX-$vm_name"
            API_BASE_URL="${PROXMOX_API_URL%/api2/json}"
            CONTAINER_IP=""

            # Déterminer si c'est un container LXC ou une VM QEMU
            if [[ "$playbook" == "install_ad_ds.yml" ]]; then
                # VM QEMU (Windows)
                RESPONSE=$(curl -k -s -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
                  "$API_BASE_URL/api2/json/nodes/${TARGET_NODE}/qemu" 2>/dev/null)

                VMID=$(echo "$RESPONSE" | grep -oE "\{[^}]*\"name\"[[:space:]]*:[[:space:]]*\"$FULL_CONTAINER_NAME\"[^}]*\}" | \
                  grep -oE "\"vmid\"[[:space:]]*:[[:space:]]*\"?[0-9]+\"?" | grep -oE "[0-9]+" | sort -n | tail -1)

                # Pour QEMU, essayer de récupérer l'IP via l'agent
                if [[ -n "$VMID" ]]; then
                    for attempt in {1..10}; do
                        AGENT_RESPONSE=$(curl -k -s -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
                          "$API_BASE_URL/api2/json/nodes/${TARGET_NODE}/qemu/$VMID/agent/network-get-interfaces" 2>/dev/null)
                        CONTAINER_IP=$(echo "$AGENT_RESPONSE" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v "127.0.0.1" | head -1)
                        [[ -n "$CONTAINER_IP" ]] && break
                        sleep 5
                    done
                fi
            else
                # Container LXC (Linux)
                RESPONSE=$(curl -k -s -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
                  "$API_BASE_URL/api2/json/nodes/${TARGET_NODE}/lxc" 2>/dev/null)

                VMID=$(echo "$RESPONSE" | grep -oE "\{[^}]*\"name\"[[:space:]]*:[[:space:]]*\"$FULL_CONTAINER_NAME\"[^}]*\}" | \
                  grep -oE "\"vmid\"[[:space:]]*:[[:space:]]*\"?[0-9]+\"?" | grep -oE "[0-9]+" | sort -n | tail -1)

                # Récupérer l'IP du container LXC
                if [[ -n "$VMID" ]]; then
                    for attempt in {1..5}; do
                        NETWORK_RESPONSE=$(curl -k -s -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
                          "$API_BASE_URL/api2/json/nodes/${TARGET_NODE}/lxc/$VMID/interfaces" 2>/dev/null)
                        CONTAINER_IP=$(echo "$NETWORK_RESPONSE" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v "127.0.0.1" | head -1)
                        [[ -n "$CONTAINER_IP" ]] && break
                        sleep 2
                    done
                fi
            fi

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
                CREDENTIALS="${YELLOW}admin / admin123${NC}"
            elif [[ "$playbook" == "install_adguard.yml" ]]; then
                SERVICE_URL="http://${CONTAINER_IP}:3000"
                SERVICE_ICON="🛡️"
                SERVICE_NAME="AdGuard Home"
                CREDENTIALS="${YELLOW}admin / admin123${NC} | DNS: ${YELLOW}${CONTAINER_IP}:53${NC}"
            elif [[ "$playbook" == "install_ad_ds.yml" ]]; then
                SERVICE_URL="RDP: ${CONTAINER_IP}:3389"
                SERVICE_ICON="🏢"
                SERVICE_NAME="Active Directory"
                AD_DOMAIN_DISPLAY="${AD_DOMAIN_NAME:-gsb.local}"
                AD_ADMIN_PASSWORD_DISPLAY="${AD_ADMIN_PASSWORD:-${WINDOWS_ADMIN_PASSWORD:-Admin123@}}"
                CREDENTIALS="${YELLOW}Administrator / ${AD_ADMIN_PASSWORD_DISPLAY}${NC} | Domaine: ${YELLOW}${AD_DOMAIN_DISPLAY}${NC}"
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
