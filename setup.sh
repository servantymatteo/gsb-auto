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
MAX_APPLY_ATTEMPTS=3

START_TIME=$(date +%s)
ENV_FILE=".env.local"
ENV_EXAMPLE=".env.local.example"

clear
echo ""
echo "╔════════════════════════════════════════╗"
echo "║  CONFIGURATION DES CONTAINERS PROXMOX  ║"
echo "╚════════════════════════════════════════╝"
echo ""

is_placeholder() {
  local value="$1"
  [[ -z "$value" || "$value" == *"xxxxxxxx"* ]]
}

default_if_empty() {
  local value="$1"
  local fallback="$2"
  if [[ -z "$value" ]]; then
    echo "$fallback"
  else
    echo "$value"
  fi
}

prompt_required() {
  local var_name="$1"
  local label="$2"
  local current="$3"
  local secret="$4"
  local answer=""

  while true; do
    if [[ "$secret" == "true" ]]; then
      read -r -s -p "$label : " answer
      echo ""
    else
      read -r -p "$label [${current}] : " answer
    fi

    if [[ -z "$answer" ]]; then
      answer="$current"
    fi

    if ! is_placeholder "$answer"; then
      printf -v "$var_name" '%s' "$answer"
      break
    fi
    echo -e "${RED}${CROSS} Valeur obligatoire${NC}"
  done
}

generate_proxmox_token_secret() {
  local token_id="$1"
  local user_part token_name generated_name out generated_secret full_token_id

  if [[ $EUID -ne 0 ]] || ! command -v pveum >/dev/null 2>&1; then
    return 1
  fi

  if [[ "$token_id" != *"!"* ]]; then
    return 1
  fi

  user_part="${token_id%%!*}"
  token_name="${token_id#*!}"
  generated_name="${token_name}-$(date +%s)"

  out=$(pveum user token add "$user_part" "$generated_name" --privsep 0 --output-format json 2>/dev/null || true)
  generated_secret=$(echo "$out" | sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

  if [[ -n "$generated_secret" ]]; then
    full_token_id="${user_part}!${generated_name}"
    PROXMOX_TOKEN_ID="$full_token_id"
    PROXMOX_TOKEN_SECRET="$generated_secret"

    # Applique explicitement les permissions token pour éviter les erreurs API (ex: VM.Monitor).
    pveum aclmod / -token "$full_token_id" -role PVEAdmin >/dev/null 2>&1 || \
    pveum aclmod / --tokens "$full_token_id" --roles PVEAdmin >/dev/null 2>&1 || \
    pveum aclmod / -user "$user_part" -role PVEAdmin >/dev/null 2>&1 || true

    return 0
  fi

  return 1
}

detect_or_create_ssh_key() {
  local project_key="ssh/id_ed25519_terraform.pub"
  local user_key_ed25519="$HOME/.ssh/id_ed25519.pub"
  local user_key_rsa="$HOME/.ssh/id_rsa.pub"

  if [[ -f "$project_key" ]]; then
    cat "$project_key"
    return 0
  fi

  if [[ -f "$user_key_ed25519" ]]; then
    cat "$user_key_ed25519"
    return 0
  fi

  if [[ -f "$user_key_rsa" ]]; then
    cat "$user_key_rsa"
    return 0
  fi

  echo -e "${YELLOW}${ARROW} Aucune clé SSH trouvée, génération automatique...${NC}" >&2
  mkdir -p ssh
  ssh-keygen -t ed25519 -f ssh/id_ed25519_terraform -N "" -C "terraform-gsb" >/dev/null 2>&1
  if [[ -f "$project_key" ]]; then
    cat "$project_key"
    return 0
  fi

  return 1
}

write_env_file() {
  cat > "$ENV_FILE" <<EOF
# Généré automatiquement par setup.sh le $(date)
PROXMOX_API_URL=$PROXMOX_API_URL
PROXMOX_TOKEN_ID=$PROXMOX_TOKEN_ID
PROXMOX_TOKEN_SECRET=$PROXMOX_TOKEN_SECRET
TARGET_NODE=$TARGET_NODE
TEMPLATE_NAME=$TEMPLATE_NAME
VM_STORAGE=$VM_STORAGE
SSH_KEYS="$SSH_KEYS"
CI_USER=$CI_USER
CI_PASSWORD=$CI_PASSWORD
EOF
}

echo -e "${CYAN}${ARROW} Vérification de la configuration...${NC}"
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ENV_EXAMPLE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    echo -e "${YELLOW}${ARROW} $ENV_FILE créé automatiquement depuis $ENV_EXAMPLE${NC}"
  else
    touch "$ENV_FILE"
    echo -e "${YELLOW}${ARROW} $ENV_FILE créé automatiquement${NC}"
  fi
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

PROXMOX_API_URL=$(default_if_empty "$PROXMOX_API_URL" "https://192.168.68.200:8006/api2/json")
TARGET_NODE=$(default_if_empty "$TARGET_NODE" "proxmox")
TEMPLATE_NAME=$(default_if_empty "$TEMPLATE_NAME" "debian-12-standard_12.12-1_amd64.tar.zst")
VM_STORAGE=$(default_if_empty "$VM_STORAGE" "local-lvm")
CI_USER=$(default_if_empty "$CI_USER" "sio2027")
CI_PASSWORD=$(default_if_empty "$CI_PASSWORD" "Formation13@")

if is_placeholder "$PROXMOX_API_URL"; then
  prompt_required "PROXMOX_API_URL" "URL API Proxmox (ex: https://IP:8006/api2/json)" "$PROXMOX_API_URL" "false"
fi

if is_placeholder "$PROXMOX_TOKEN_ID"; then
  prompt_required "PROXMOX_TOKEN_ID" "Token ID Proxmox (ex: root@pam!terraform)" "$PROXMOX_TOKEN_ID" "false"
fi

if is_placeholder "$PROXMOX_TOKEN_SECRET"; then
  if generate_proxmox_token_secret "$PROXMOX_TOKEN_ID"; then
    echo -e "${GREEN}${CHECK} Token Proxmox généré automatiquement: ${PROXMOX_TOKEN_ID}${NC}"
  else
    prompt_required "PROXMOX_TOKEN_SECRET" "Token secret Proxmox" "" "true"
  fi
fi

if is_placeholder "$SSH_KEYS"; then
  SSH_KEYS=$(detect_or_create_ssh_key)
  if [[ -z "$SSH_KEYS" ]]; then
    echo -e "${RED}${CROSS} Impossible de détecter/générer une clé SSH${NC}"
    exit 1
  fi
  echo -e "${GREEN}${CHECK} Clé SSH publique détectée automatiquement${NC}"
fi

write_env_file
echo -e "${GREEN}${CHECK} Configuration chargée et mise à jour${NC}"
echo ""

echo -e "${BOLD}${BLUE}━━━ Configuration de base ━━━${NC}"
echo ""
while true; do
  read -r -p "Préfixe des containers (ex: SIO2027) : " VM_PREFIX
  if [[ -n "$VM_PREFIX" ]]; then
    break
  fi
  echo -e "${RED}${CROSS} Le préfixe ne peut pas être vide${NC}"
done
echo ""

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

echo -e "${BOLD}${MAGENTA}━━━ Services disponibles ━━━${NC}"
echo ""
for i in "${!SERVICE_NAMES[@]}"; do
  echo -e "  ${CYAN}[$i]${NC} ${SERVICE_NAMES[$i]}"
done
echo ""

while true; do
  read -r -p "Quels services voulez-vous installer ? (ex: 1 2 ou 1,2) : " services_input
  if [[ -n "$services_input" ]]; then
    break
  fi
  echo -e "${RED}${CROSS} Veuillez sélectionner au moins un service${NC}"
done
services_input=$(echo "$services_input" | tr ',' ' ')
echo ""

read -r -p "Utiliser les ressources recommandées pour tous les services ? (O/n) : " use_defaults
use_defaults=${use_defaults:-O}
echo ""

declare -a VM_NAMES
declare -a VM_CONFIGS

for service_num in $services_input; do
  if [[ -z "${SERVICE_NAMES[$service_num]}" ]]; then
    continue
  fi

  IFS='|' read -r default_name default_cores default_memory default_disk <<< "${SERVICE_DEFAULTS[$service_num]}"
  vm_name="$default_name"
  vm_cores="$default_cores"
  vm_memory="$default_memory"
  vm_disk="$default_disk"

  if [[ "$use_defaults" == "n" || "$use_defaults" == "N" ]]; then
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}${GEAR}  Configuration : ${SERVICE_NAMES[$service_num]}${NC}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${CYAN}Nom du container${NC} [${BOLD}$default_name${NC}]"
    read -r -p "> " vm_name
    vm_name=${vm_name:-$default_name}

    echo -e "${CYAN}CPU cores${NC} [${BOLD}$default_cores${NC}]"
    read -r -p "> " vm_cores
    vm_cores=${vm_cores:-$default_cores}

    echo -e "${CYAN}RAM en MB${NC} [${BOLD}$default_memory${NC}]"
    read -r -p "> " vm_memory
    vm_memory=${vm_memory:-$default_memory}

    echo -e "${CYAN}Taille du disque${NC} [${BOLD}$default_disk${NC}]"
    read -r -p "> " vm_disk
    vm_disk=${vm_disk:-$default_disk}

    echo ""
  fi

  VM_NAMES+=("$vm_name")
  VM_CONFIGS+=("${vm_cores}|${vm_memory}|${vm_disk}|${SERVICE_PLAYBOOKS[$service_num]}")
  echo -e "${GREEN}${CHECK} ${SERVICE_NAMES[$service_num]} configuré (${vm_name})${NC}"
done
echo ""

echo -e "${BOLD}${YELLOW}━━━ Génération de la configuration ━━━${NC}"
echo -e "${CYAN}${ARROW} Création du fichier terraform/terraform.tfvars...${NC}"

cat > terraform/terraform.tfvars <<EOF
# Configuration générée automatiquement par setup.sh
# Date: $(date)

pm_api_url = "$PROXMOX_API_URL"
pm_api_token_id     = "$PROXMOX_TOKEN_ID"
pm_api_token_secret = "$PROXMOX_TOKEN_SECRET"

vm_name       = "$VM_PREFIX"
target_node   = "$TARGET_NODE"
template_name = "$TEMPLATE_NAME"
vm_storage    = "$VM_STORAGE"

ci_user     = "$CI_USER"
ci_password = "$CI_PASSWORD"
ssh_keys    = "$SSH_KEYS"

vms = {
EOF

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
echo "}" >> terraform/terraform.tfvars

echo -e "${GREEN}${CHECK} Fichier généré avec succès${NC}"
echo ""

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║       CONFIGURATION TERMINÉE ! ${CHECK}              ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}${BLUE}Containers à déployer :${NC}"
echo ""

for i in "${!VM_NAMES[@]}"; do
  vm_name="${VM_NAMES[$i]}"
  IFS='|' read -r cores memory disk playbook <<< "${VM_CONFIGS[$i]}"

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

echo -e "${BOLD}${YELLOW}Lancer le déploiement maintenant ? (O/n)${NC}"
read -r -p "> " launch
launch=${launch:-O}

if [[ "$launch" == "o" || "$launch" == "O" ]]; then
  echo ""
  echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${MAGENTA}${ROCKET}  DÉPLOIEMENT EN COURS...${NC}"
  echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  DEPLOY_START=$(date +%s)
  cd terraform || exit 1

  echo -e "${CYAN}${ARROW} Initialisation de Terraform...${NC}"
  TF_IN_AUTOMATION=1 terraform init -input=false -compact-warnings
  INIT_STATUS=$?

  DEPLOY_STATUS=1
  if [ $INIT_STATUS -eq 0 ]; then
    for attempt in $(seq 1 $MAX_APPLY_ATTEMPTS); do
      echo ""
      echo -e "${CYAN}${ARROW} Terraform apply (tentative ${attempt}/${MAX_APPLY_ATTEMPTS})...${NC}"
      TF_IN_AUTOMATION=1 terraform apply --auto-approve -compact-warnings
      DEPLOY_STATUS=$?

      if [ $DEPLOY_STATUS -eq 0 ]; then
        break
      fi

      if [ $attempt -lt $MAX_APPLY_ATTEMPTS ]; then
        echo -e "${YELLOW}${ARROW} Échec, nouvelle tentative dans 8 secondes...${NC}"
        sleep 8
      fi
    done
  else
    DEPLOY_STATUS=$INIT_STATUS
  fi

  cd .. || exit 1
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

    echo -e "${BOLD}${BLUE}━━━ Services déployés ━━━${NC}"
    echo ""
    for i in "${!VM_NAMES[@]}"; do
      vm_name="${VM_NAMES[$i]}"
      IFS='|' read -r _ _ _ playbook <<< "${VM_CONFIGS[$i]}"

      cd terraform || exit 1
      CONTAINER_IP=$(terraform state show "proxmox_lxc.container[\"$vm_name\"]" 2>/dev/null | grep "ipv4_addresses" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
      cd .. || exit 1

      if [[ -z "$CONTAINER_IP" ]]; then
        CONTAINER_IP="IP non trouvée"
      fi

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
        echo -e "     ${CREDENTIALS}"
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
