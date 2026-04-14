#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# UI
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_title() { echo -e "\n${BOLD}${CYAN}== $* ==${NC}"; }
log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*"; }

prompt_password_if_missing() {
  if [[ -z "${PROXMOX_PASSWORD:-}" || "${PROXMOX_PASSWORD}" == "ton_mdp" ]]; then
    log_err "Mot de passe Proxmox manquant (aucune invite interactive). Exporte PROXMOX_PASSWORD si tu veux le fallback password."
    exit 1
  fi
}

MAX_APPLY_ATTEMPTS="${MAX_APPLY_ATTEMPTS:-3}"
CLEANUP_AT_END="${CLEANUP_AT_END:-1}"
VM_PREFIX="${VM_PREFIX:-GSB}"
TARGET_NODE="${TARGET_NODE:-$(hostname)}"
PROXMOX_API_URL="${PROXMOX_API_URL:-https://127.0.0.1:8006/api2/json}"
TEMPLATE_NAME="${TEMPLATE_NAME:-debian-12-standard_12.12-1_amd64.tar.zst}"
VM_STORAGE="${VM_STORAGE:-local-lvm}"
CI_USER="${CI_USER:-admin}"
CI_PASSWORD="${CI_PASSWORD:-Formation13@}"
TOKEN_USER="${TOKEN_USER:-terraform-prov@pve}"
TOKEN_NAME="${TOKEN_NAME:-auto-token}"
PROXMOX_TOKEN_PRIVSEP="${PROXMOX_TOKEN_PRIVSEP:-0}"
PROXMOX_USER="${PROXMOX_USER:-root@pam}"
PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-}"
PROXMOX_AUTH_PREFERENCE="${PROXMOX_AUTH_PREFERENCE:-token}"

DEPLOY_APACHE="${DEPLOY_APACHE:-1}"
DEPLOY_GLPI="${DEPLOY_GLPI:-1}"
DEPLOY_UPTIME="${DEPLOY_UPTIME:-1}"
DEPLOY_WSERV="${DEPLOY_WSERV:-0}"
DEPLOY_AD="${DEPLOY_AD:-0}"
WEB_NAME="${WEB_NAME:-web}"
WEB_CORES="${WEB_CORES:-2}"
WEB_MEMORY="${WEB_MEMORY:-2048}"
WEB_DISK="${WEB_DISK:-10G}"
GLPI_NAME="${GLPI_NAME:-glpi}"
GLPI_CORES="${GLPI_CORES:-2}"
GLPI_MEMORY="${GLPI_MEMORY:-4096}"
GLPI_DISK="${GLPI_DISK:-20G}"
UPTIME_NAME="${UPTIME_NAME:-monitoring}"
UPTIME_CORES="${UPTIME_CORES:-2}"
UPTIME_MEMORY="${UPTIME_MEMORY:-2048}"
UPTIME_DISK="${UPTIME_DISK:-15G}"
AD_DC_NAME="${AD_DC_NAME:-dc01}"
AD_DC_CORES="${AD_DC_CORES:-2}"
AD_DC_MEMORY="${AD_DC_MEMORY:-4096}"
AD_DC_DISK="${AD_DC_DISK:-20G}"
WSERV_NAME="${WSERV_NAME:-wserv}"
WSERV_VM_ID="${WSERV_VM_ID:-210}"
WSERV_CORES="${WSERV_CORES:-4}"
WSERV_MEMORY="${WSERV_MEMORY:-6144}"
WSERV_DISK="${WSERV_DISK:-40G}"
WSERV_ADMIN_USER="${WSERV_ADMIN_USER:-Administrateur}"
WSERV_ADMIN_PASSWORD="${WSERV_ADMIN_PASSWORD:-Formation13@}"
WINDOWS_TEMPLATE_VMID="${WINDOWS_TEMPLATE_VMID:-2000}"
WINDOWS_DOMAIN_NAME="${WINDOWS_DOMAIN_NAME:-gsb.local}"
WINDOWS_DOMAIN_NETBIOS="${WINDOWS_DOMAIN_NETBIOS:-GSB}"
WINDOWS_SAFE_MODE_PASSWORD="${WINDOWS_SAFE_MODE_PASSWORD:-Formation13@}"
WINDOWS_ENABLE_AGENT="${WINDOWS_ENABLE_AGENT:-1}"
AD_OU_LIST="${AD_OU_LIST:-}"
AD_GROUP_LIST="${AD_GROUP_LIST:-}"
AD_USER_LIST="${AD_USER_LIST:-}"
AD_DEFAULT_USER_PASSWORD="${AD_DEFAULT_USER_PASSWORD:-Formation13@}"
WSERV_IP="${WSERV_IP:-}"
WINDOWS_IP_WAIT_SECONDS="${WINDOWS_IP_WAIT_SECONDS:-180}"
WINDOWS_IP_RETRY_INTERVAL="${WINDOWS_IP_RETRY_INTERVAL:-5}"

SSH_PUB_KEY=""
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-}"
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"
AUTH_MODE_SELECTED=""
AUTO_TOKEN_CREATED=0
WSERV_RESOLVED_IP=""

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log_err "Command not found: $1"
    exit 1
  }
}

detect_or_create_ssh_key() {
  if [[ -f "ssh/id_ed25519_terraform.pub" ]]; then
    cat "ssh/id_ed25519_terraform.pub"
    return 0
  fi
  if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    cat "$HOME/.ssh/id_ed25519.pub"
    return 0
  fi
  if [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
    cat "$HOME/.ssh/id_rsa.pub"
    return 0
  fi

  mkdir -p ssh
  ssh-keygen -t ed25519 -f "ssh/id_ed25519_terraform" -N "" -C "terraform-gsb" >/dev/null 2>&1
  cat "ssh/id_ed25519_terraform.pub"
}

setup_token_when_possible() {
  if [[ $EUID -ne 0 ]] || ! command -v pveum >/dev/null 2>&1; then
    return 1
  fi

  TOKEN_USER="${PROXMOX_USER}"
  [[ "$TOKEN_USER" != *"@"* ]] && TOKEN_USER="root@pam"

  pveum user token delete "$TOKEN_USER" "$TOKEN_NAME" >/dev/null 2>&1 || true
  local token_output
  token_output="$(pveum user token add "$TOKEN_USER" "$TOKEN_NAME" --privsep 0 --output-format json)"

  PROXMOX_TOKEN_ID="${TOKEN_USER}!${TOKEN_NAME}"
  PROXMOX_TOKEN_SECRET="$(echo "$token_output" | sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  AUTO_TOKEN_CREATED=1

  [[ -n "$PROXMOX_TOKEN_SECRET" ]]
}

token_has_provider_level_access() {
  local base_url status
  base_url="${PROXMOX_API_URL%/api2/json}"
  status="$(curl -k -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
    "${base_url}/api2/json/access/users")"
  [[ "$status" == "200" ]]
}

token_has_vm_monitor_access() {
  local base_url status
  base_url="${PROXMOX_API_URL%/api2/json}"
  status="$(curl -k -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
    "${base_url}/api2/json/nodes/${TARGET_NODE}/lxc")"
  [[ "$status" == "200" ]]
}

password_has_provider_level_access() {
  local base_url auth_response ticket status
  base_url="${PROXMOX_API_URL%/api2/json}"
  auth_response="$(curl -k -s \
    --data-urlencode "username=${PROXMOX_USER}" \
    --data-urlencode "password=${PROXMOX_PASSWORD}" \
    "${base_url}/api2/json/access/ticket")"
  ticket="$(echo "$auth_response" | sed -n 's/.*"ticket"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  [[ -z "$ticket" ]] && return 1

  status="$(curl -k -s -o /dev/null -w "%{http_code}" \
    -H "Cookie: PVEAuthCookie=${ticket}" \
    "${base_url}/api2/json/access/users")"
  [[ "$status" == "200" ]]
}

password_has_vm_monitor_access() {
  local base_url auth_response ticket status
  base_url="${PROXMOX_API_URL%/api2/json}"
  auth_response="$(curl -k -s \
    --data-urlencode "username=${PROXMOX_USER}" \
    --data-urlencode "password=${PROXMOX_PASSWORD}" \
    "${base_url}/api2/json/access/ticket")"
  ticket="$(echo "$auth_response" | sed -n 's/.*"ticket"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  [[ -z "$ticket" ]] && return 1

  status="$(curl -k -s -o /dev/null -w "%{http_code}" \
    -H "Cookie: PVEAuthCookie=${ticket}" \
    "${base_url}/api2/json/nodes/${TARGET_NODE}/lxc")"
  [[ "$status" == "200" ]]
}

get_ip_from_terraform_state() {
  local resource_addr="$1"
  terraform state show "$resource_addr" 2>/dev/null \
    | grep -E 'ipv4|ip=' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -v '^127\.' \
    | head -n 1 || true
}

get_ip_from_proxmox_api() {
  local container_full_name="$1"
  local base_url auth_response ticket lxc_list vmid interfaces ip token_id token_secret

  base_url="${PROXMOX_API_URL%/api2/json}"

  token_id="${PROXMOX_TOKEN_ID:-}"
  token_secret="${PROXMOX_TOKEN_SECRET:-}"

  if [[ "$AUTH_MODE_SELECTED" == "token" && -n "$token_id" && -n "$token_secret" ]]; then
    lxc_list="$(curl -k -s -H "Authorization: PVEAPIToken=${token_id}=${token_secret}" \
      "${base_url}/api2/json/nodes/${TARGET_NODE}/lxc" 2>/dev/null || true)"
  else
    auth_response="$(curl -k -s \
      --data-urlencode "username=${PROXMOX_USER}" \
      --data-urlencode "password=${PROXMOX_PASSWORD}" \
      "${base_url}/api2/json/access/ticket" 2>/dev/null || true)"
    ticket="$(echo "$auth_response" | sed -n 's/.*"ticket"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    [[ -z "$ticket" ]] && return 0
    lxc_list="$(curl -k -s -H "Cookie: PVEAuthCookie=${ticket}" \
      "${base_url}/api2/json/nodes/${TARGET_NODE}/lxc" 2>/dev/null || true)"
  fi

  vmid="$(echo "$lxc_list" | grep -o "{[^}]*\"name\":\"${container_full_name}\"[^}]*}" \
    | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*' | head -n 1 || true)"
  [[ -z "$vmid" ]] && return 0

  if [[ "$AUTH_MODE_SELECTED" == "token" && -n "$token_id" && -n "$token_secret" ]]; then
    interfaces="$(curl -k -s -H "Authorization: PVEAPIToken=${token_id}=${token_secret}" \
      "${base_url}/api2/json/nodes/${TARGET_NODE}/lxc/${vmid}/interfaces" 2>/dev/null || true)"
  else
    interfaces="$(curl -k -s -H "Cookie: PVEAuthCookie=${ticket}" \
      "${base_url}/api2/json/nodes/${TARGET_NODE}/lxc/${vmid}/interfaces" 2>/dev/null || true)"
  fi

  ip="$(echo "$interfaces" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | head -n 1 || true)"
  echo "$ip"
}

resolve_container_ip() {
  local short_name="$1"
  local resource_addr="proxmox_virtual_environment_container.container[\"${short_name}\"]"
  local full_name="${VM_PREFIX}-${short_name}"
  local ip

  ip="$(get_ip_from_terraform_state "$resource_addr")"
  if [[ -z "$ip" ]]; then
    ip="$(get_ip_from_proxmox_api "$full_name")"
  fi
  echo "$ip"
}

resolve_windows_ip() {
  local ip=""

  pushd terraform >/dev/null
  ip="$(terraform state show "proxmox_virtual_environment_vm.windows[\"$WSERV_NAME\"]" 2>/dev/null \
    | grep -E 'ipv4_addresses|ipv4' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -v '^127\.' \
    | head -n 1 || true)"
  popd >/dev/null

  if [[ -z "$ip" ]] && [[ $EUID -eq 0 ]] && command -v qm >/dev/null 2>&1; then
    ip="$(qm guest cmd "$WSERV_VM_ID" network-get-interfaces 2>/dev/null \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | grep -v '^127\.' \
      | head -n 1 || true)"
  fi

  [[ -z "$ip" && -n "$WSERV_IP" ]] && ip="$WSERV_IP"
  echo "$ip"
}

wait_for_windows_ip() {
  local waited=0
  local timeout="$WINDOWS_IP_WAIT_SECONDS"
  local interval="$WINDOWS_IP_RETRY_INTERVAL"
  local ip=""

  while [[ "$waited" -le "$timeout" ]]; do
    ip="$(resolve_windows_ip)"
    if [[ -n "$ip" ]]; then
      WSERV_RESOLVED_IP="$ip"
      return 0
    fi

    if [[ "$waited" -eq 0 ]]; then
      log_info "Attente de l'IP Windows via QEMU Guest Agent (${timeout}s max)..."
    fi

    sleep "$interval"
    waited=$((waited + interval))
  done

  return 1
}

cleanup() {
  if [[ "$CLEANUP_AT_END" != "1" ]]; then
    return 0
  fi

  rm -f .env.local
  rm -f terraform/terraform.tfvars

  if [[ $AUTO_TOKEN_CREATED -eq 1 && $EUID -eq 0 ]] && command -v pveum >/dev/null 2>&1; then
    pveum aclmod / -delete -token "$TOKEN_USER!$TOKEN_NAME" >/dev/null 2>&1 || true
    pveum user token delete "$TOKEN_USER" "$TOKEN_NAME" >/dev/null 2>&1 || true
  fi
}

prompt_with_default() {
  local __var="$1"
  local __label="$2"
  local __default="$3"
  local __input=""
  read -r -p "$__label [$__default]: " __input
  if [[ -z "$__input" ]]; then
    printf -v "$__var" '%s' "$__default"
  else
    printf -v "$__var" '%s' "$__input"
  fi
}

apply_preset_company_structure() {
  AD_OU_LIST="Direction,IT,RH,Comptabilite,Commercial"
  AD_GROUP_LIST="GSB-Direction,GSB-IT,GSB-RH,GSB-Comptabilite,GSB-Commercial,GSB-Admins"
  AD_USER_LIST="dir.general,admin.sys,technicien,responsable.rh,gestionnaire.rh,comptable,commercial1,commercial2"
  log_ok "Structure prédéfinie appliquée :"
  echo -e "  ${CYAN}OUs    :${NC} ${AD_OU_LIST}"
  echo -e "  ${CYAN}Groupes:${NC} ${AD_GROUP_LIST}"
  echo -e "  ${CYAN}Users  :${NC} ${AD_USER_LIST}"
  echo -e "  ${CYAN}MDP    :${NC} ${AD_DEFAULT_USER_PASSWORD}"
}

prompt_ad_structure() {
  echo ""
  echo -e "${CYAN}Structure Active Directory :${NC}"
  echo "  [1] Aucune (AD vide)"
  echo "  [2] Structure d'entreprise prédéfinie"
  echo "       OUs     : Direction, IT, RH, Comptabilite, Commercial"
  echo "       Groupes : GSB-Direction, GSB-IT, GSB-RH, GSB-Comptabilite, GSB-Commercial, GSB-Admins"
  echo "       Users   : dir.general, admin.sys, technicien, responsable.rh, gestionnaire.rh, comptable, commercial1, commercial2"
  echo "  [3] Personnalisé (saisir manuellement)"
  local ad_choice=""
  read -r -p "Choix [1]: " ad_choice
  ad_choice="${ad_choice:-1}"

  case "$ad_choice" in
    2)
      apply_preset_company_structure
      prompt_with_default AD_DEFAULT_USER_PASSWORD "Mot de passe utilisateurs AD" "$AD_DEFAULT_USER_PASSWORD"
      ;;
    3)
      prompt_with_default AD_OU_LIST "Liste OU (CSV, ex: IT,RH)" "$AD_OU_LIST"
      prompt_with_default AD_GROUP_LIST "Liste groupes AD (CSV, ex: GSB-Admins,GSB-Users)" "$AD_GROUP_LIST"
      prompt_with_default AD_USER_LIST "Liste users AD (CSV, ex: alice,bob,carol)" "$AD_USER_LIST"
      prompt_with_default AD_DEFAULT_USER_PASSWORD "Mot de passe utilisateurs AD" "$AD_DEFAULT_USER_PASSWORD"
      ;;
    *)
      AD_OU_LIST=""
      AD_GROUP_LIST=""
      AD_USER_LIST=""
      ;;
  esac
}

prompt_deployment_plan_if_interactive() {
  if [[ ! -t 0 ]]; then
    exec < /dev/tty
  fi

  log_title "Plan de déploiement"
  prompt_with_default VM_PREFIX "Préfixe des containers" "$VM_PREFIX"

  echo -e "${CYAN}Services disponibles:${NC}"
  echo "  [1] Apache"
  echo "  [2] GLPI"
  echo "  [3] Uptime Kuma"
  echo "  [4] Windows Server"
  echo "  [5] Active Directory (Samba DC)"

  local services_input=""
  read -r -p "Services à déployer (ex: 1 2 3 4 5) [1 2 3]: " services_input
  services_input="${services_input:-1 2 3}"
  services_input="$(echo "$services_input" | tr ',' ' ')"

  DEPLOY_APACHE=0
  DEPLOY_GLPI=0
  DEPLOY_UPTIME=0
  DEPLOY_WSERV=0
  DEPLOY_AD=0
  for s in $services_input; do
    [[ "$s" == "1" ]] && DEPLOY_APACHE=1
    [[ "$s" == "2" ]] && DEPLOY_GLPI=1
    [[ "$s" == "3" ]] && DEPLOY_UPTIME=1
    [[ "$s" == "4" ]] && DEPLOY_WSERV=1
    [[ "$s" == "5" ]] && DEPLOY_AD=1
  done

  if [[ "$DEPLOY_APACHE" == "0" && "$DEPLOY_GLPI" == "0" && "$DEPLOY_UPTIME" == "0" && "$DEPLOY_WSERV" == "0" && "$DEPLOY_AD" == "0" ]]; then
    log_warn "Aucun service sélectionné, Apache activé par défaut."
    DEPLOY_APACHE=1
  fi

  local use_defaults="O"
  read -r -p "Utiliser les ressources recommandées ? (O/n): " use_defaults
  use_defaults="${use_defaults:-O}"

  if [[ "$DEPLOY_WSERV" == "1" ]]; then
    log_info "Configuration Windows Server"
    prompt_with_default WINDOWS_TEMPLATE_VMID "VMID template Windows à cloner" "$WINDOWS_TEMPLATE_VMID"
    prompt_with_default WSERV_VM_ID "VMID cible de la VM Windows (nouvelle VM)" "$WSERV_VM_ID"
    prompt_ad_structure
  fi

  if [[ "$DEPLOY_AD" == "1" ]]; then
    log_info "Configuration Active Directory (Samba DC)"
    prompt_ad_structure
  fi

  if [[ "$use_defaults" == "n" || "$use_defaults" == "N" ]]; then
    if [[ "$DEPLOY_APACHE" == "1" ]]; then
      log_info "Configuration Apache"
      prompt_with_default WEB_NAME "Nom container Apache" "$WEB_NAME"
      prompt_with_default WEB_CORES "CPU Apache" "$WEB_CORES"
      prompt_with_default WEB_MEMORY "RAM Apache (MB)" "$WEB_MEMORY"
      prompt_with_default WEB_DISK "Disque Apache" "$WEB_DISK"
    fi
    if [[ "$DEPLOY_GLPI" == "1" ]]; then
      log_info "Configuration GLPI"
      prompt_with_default GLPI_NAME "Nom container GLPI" "$GLPI_NAME"
      prompt_with_default GLPI_CORES "CPU GLPI" "$GLPI_CORES"
      prompt_with_default GLPI_MEMORY "RAM GLPI (MB)" "$GLPI_MEMORY"
      prompt_with_default GLPI_DISK "Disque GLPI" "$GLPI_DISK"
    fi
    if [[ "$DEPLOY_UPTIME" == "1" ]]; then
      log_info "Configuration Uptime Kuma"
      prompt_with_default UPTIME_NAME "Nom container Uptime" "$UPTIME_NAME"
      prompt_with_default UPTIME_CORES "CPU Uptime" "$UPTIME_CORES"
      prompt_with_default UPTIME_MEMORY "RAM Uptime (MB)" "$UPTIME_MEMORY"
      prompt_with_default UPTIME_DISK "Disque Uptime" "$UPTIME_DISK"
    fi
    if [[ "$DEPLOY_WSERV" == "1" ]]; then
      prompt_with_default WSERV_NAME "Nom VM Windows" "$WSERV_NAME"
      prompt_with_default WSERV_CORES "CPU Windows" "$WSERV_CORES"
      prompt_with_default WSERV_MEMORY "RAM Windows (MB)" "$WSERV_MEMORY"
      prompt_with_default WSERV_DISK "Disque Windows" "$WSERV_DISK"
      prompt_with_default WSERV_ADMIN_USER "Utilisateur WinRM" "$WSERV_ADMIN_USER"
      prompt_with_default WSERV_ADMIN_PASSWORD "Mot de passe WinRM" "$WSERV_ADMIN_PASSWORD"
      prompt_with_default WSERV_IP "IP Windows (optionnel, recommandé)" "$WSERV_IP"
      prompt_with_default WINDOWS_DOMAIN_NAME "Nom domaine AD (DNS)" "$WINDOWS_DOMAIN_NAME"
      prompt_with_default WINDOWS_DOMAIN_NETBIOS "Nom domaine AD (NetBIOS)" "$WINDOWS_DOMAIN_NETBIOS"
      prompt_with_default WINDOWS_SAFE_MODE_PASSWORD "Mot de passe DSRM AD" "$WINDOWS_SAFE_MODE_PASSWORD"
      local qga_input="N"
      read -r -p "Le template Windows a QEMU Guest Agent actif ? (o/N): " qga_input
      if [[ "$qga_input" == "o" || "$qga_input" == "O" ]]; then
        WINDOWS_ENABLE_AGENT=1
      else
        WINDOWS_ENABLE_AGENT=0
      fi
    fi
    if [[ "$DEPLOY_AD" == "1" ]]; then
      log_info "Ressources Active Directory (Samba DC)"
      prompt_with_default AD_DC_NAME "Nom container DC" "$AD_DC_NAME"
      prompt_with_default AD_DC_CORES "CPU DC" "$AD_DC_CORES"
      prompt_with_default AD_DC_MEMORY "RAM DC (MB)" "$AD_DC_MEMORY"
      prompt_with_default AD_DC_DISK "Disque DC" "$AD_DC_DISK"
    fi
  fi
}

validate_windows_plan() {
  if [[ "$DEPLOY_WSERV" != "1" ]]; then
    return 0
  fi

  if [[ "$WSERV_VM_ID" == "$WINDOWS_TEMPLATE_VMID" ]]; then
    log_err "Configuration invalide: VMID cible (${WSERV_VM_ID}) identique au VMID template (${WINDOWS_TEMPLATE_VMID})."
    log_err "Utilise deux VMID différents (ex: template=201, cible=210)."
    exit 1
  fi
}

write_env_file() {
  cat > .env.local <<EOF
PROXMOX_API_URL=$PROXMOX_API_URL
PROXMOX_TOKEN_ID=$PROXMOX_TOKEN_ID
PROXMOX_TOKEN_SECRET=$PROXMOX_TOKEN_SECRET
PROXMOX_USER=$PROXMOX_USER
PROXMOX_PASSWORD=$PROXMOX_PASSWORD
TARGET_NODE=$TARGET_NODE
TEMPLATE_NAME=$TEMPLATE_NAME
VM_STORAGE=$VM_STORAGE
SSH_KEYS="$SSH_PUB_KEY"
CI_USER=$CI_USER
CI_PASSWORD=$CI_PASSWORD
EOF
}

write_tfvars() {
  local tf_pm_user=""
  local tf_pm_password=""
  local tf_pm_token_id=""
  local tf_pm_token_secret=""

  if [[ "$AUTH_MODE_SELECTED" == "token" && -n "${PROXMOX_TOKEN_ID}" && -n "${PROXMOX_TOKEN_SECRET}" ]]; then
    tf_pm_token_id="$PROXMOX_TOKEN_ID"
    tf_pm_token_secret="$PROXMOX_TOKEN_SECRET"
  else
    tf_pm_token_id=""
    tf_pm_token_secret=""
    tf_pm_user="$PROXMOX_USER"
    tf_pm_password="$PROXMOX_PASSWORD"
  fi

  cat > terraform/terraform.tfvars <<EOF
pm_api_url = "$PROXMOX_API_URL"
pm_api_token_id     = "$tf_pm_token_id"
pm_api_token_secret = "$tf_pm_token_secret"
pm_user             = "$tf_pm_user"
pm_password         = "$tf_pm_password"

vm_name       = "$VM_PREFIX"
target_node   = "$TARGET_NODE"
template_name = "$TEMPLATE_NAME"
vm_storage    = "$VM_STORAGE"

ci_user     = "$CI_USER"
ci_password = "$CI_PASSWORD"
ssh_keys    = "$SSH_PUB_KEY"

vms = {
EOF

  if [[ "$DEPLOY_APACHE" == "1" ]]; then
    cat >> terraform/terraform.tfvars <<EOF
  "$WEB_NAME" = {
    cores     = $WEB_CORES
    memory    = $WEB_MEMORY
    disk_size = "$WEB_DISK"
    playbook  = "install_apache.yml"
  }
EOF
  fi

  if [[ "$DEPLOY_GLPI" == "1" ]]; then
    cat >> terraform/terraform.tfvars <<EOF
  "$GLPI_NAME" = {
    cores     = $GLPI_CORES
    memory    = $GLPI_MEMORY
    disk_size = "$GLPI_DISK"
    playbook  = "install_glpi.yml"
  }
EOF
  fi

  if [[ "$DEPLOY_UPTIME" == "1" ]]; then
    cat >> terraform/terraform.tfvars <<EOF
  "$UPTIME_NAME" = {
    cores     = $UPTIME_CORES
    memory    = $UPTIME_MEMORY
    disk_size = "$UPTIME_DISK"
    playbook  = "install_uptime_kuma.yml"
  }
EOF
  fi

  if [[ "$DEPLOY_AD" == "1" ]]; then
    cat >> terraform/terraform.tfvars <<EOF
  "$AD_DC_NAME" = {
    cores     = $AD_DC_CORES
    memory    = $AD_DC_MEMORY
    disk_size = "$AD_DC_DISK"
    playbook  = "install_samba_ad.yml"
  }
EOF
  fi

  cat >> terraform/terraform.tfvars <<EOF
}

windows_vms = {
EOF

  if [[ "$DEPLOY_WSERV" == "1" ]]; then
    cat >> terraform/terraform.tfvars <<EOF
  "$WSERV_NAME" = {
    vm_id     = $WSERV_VM_ID
    cores     = $WSERV_CORES
    memory    = $WSERV_MEMORY
    disk_size = "$WSERV_DISK"
    playbook  = "install_wserv.yml"
  }
EOF
  fi

  cat >> terraform/terraform.tfvars <<EOF
}

windows_template_vmid = $WINDOWS_TEMPLATE_VMID
windows_admin_user = "$WSERV_ADMIN_USER"
windows_admin_password = "$WSERV_ADMIN_PASSWORD"
windows_domain_name = "$WINDOWS_DOMAIN_NAME"
windows_domain_netbios = "$WINDOWS_DOMAIN_NETBIOS"
windows_safe_mode_password = "$WINDOWS_SAFE_MODE_PASSWORD"
windows_enable_agent = $([[ "$WINDOWS_ENABLE_AGENT" == "1" ]] && echo "true" || echo "false")
EOF
}

run_terraform() {
  # Empêche les variables d'environnement Proxmox de surcharger le mode d'auth choisi.
  unset PM_API_TOKEN_ID PM_API_TOKEN_SECRET PM_USER PM_PASS PM_PASSWORD
  unset PROXMOX_VE_API_TOKEN PROXMOX_VE_USERNAME PROXMOX_VE_PASSWORD PROXMOX_VE_AUTH_TICKET PROXMOX_VE_CSRF_PREVENTION_TOKEN

  pushd terraform >/dev/null
  log_title "Terraform Init"
  TF_IN_AUTOMATION=1 terraform init -input=false -compact-warnings

  local attempt
  for attempt in $(seq 1 "$MAX_APPLY_ATTEMPTS"); do
    log_title "Terraform Apply ${attempt}/${MAX_APPLY_ATTEMPTS}"
    if TF_IN_AUTOMATION=1 terraform apply --auto-approve -compact-warnings; then
      popd >/dev/null
      return 0
    fi
    if [[ "$attempt" -lt "$MAX_APPLY_ATTEMPTS" ]]; then
      log_warn "Apply failed, retry in 8s..."
      sleep 8
    fi
  done

  popd >/dev/null
  return 1
}

print_service_urls() {
  echo ""
  echo -e "${BOLD}${CYAN}=== Récapitulatif d'accès ===${NC}"
  local ip_web ip_glpi ip_uptime ip_wserv
  pushd terraform >/dev/null
  ip_web="$(resolve_container_ip "$WEB_NAME")"
  ip_glpi="$(resolve_container_ip "$GLPI_NAME")"
  ip_uptime="$(resolve_container_ip "$UPTIME_NAME")"
  popd >/dev/null
  ip_wserv="${WSERV_RESOLVED_IP:-}"
  [[ -z "$ip_wserv" ]] && ip_wserv="$(resolve_windows_ip)"

  if [[ "$DEPLOY_APACHE" == "1" ]]; then
    echo ""
    echo -e "${BOLD}Apache${NC}"
    echo "  Container : ${VM_PREFIX}-${WEB_NAME}"
    echo "  IP        : ${ip_web:-non trouvée}"
    echo "  Port      : 80"
    [[ -n "$ip_web" ]] && echo "  URL       : http://${ip_web}"
    echo "  Login web : aucun (page web publique)"
    echo "  Login CT  : ${CI_USER} / ${CI_PASSWORD}"
  fi

  if [[ "$DEPLOY_GLPI" == "1" ]]; then
    echo ""
    echo -e "${BOLD}GLPI${NC}"
    echo "  Container : ${VM_PREFIX}-${GLPI_NAME}"
    echo "  IP        : ${ip_glpi:-non trouvée}"
    echo "  Port      : 80"
    [[ -n "$ip_glpi" ]] && echo "  URL       : http://${ip_glpi}/glpi"
    echo "  Login CT  : ${CI_USER} / ${CI_PASSWORD}"
    echo "  Login GLPI: glpi / glpi"
  fi

  if [[ "$DEPLOY_UPTIME" == "1" ]]; then
    echo ""
    echo -e "${BOLD}Uptime Kuma${NC}"
    echo "  Container : ${VM_PREFIX}-${UPTIME_NAME}"
    echo "  IP        : ${ip_uptime:-non trouvée}"
    echo "  Port      : 3001"
    [[ -n "$ip_uptime" ]] && echo "  URL       : http://${ip_uptime}:3001"
    echo "  Login     : création au premier accès"
  fi

  if [[ "$DEPLOY_WSERV" == "1" ]]; then
    echo ""
    echo -e "${BOLD}Windows Server${NC}"
    echo "  VM        : ${VM_PREFIX}-${WSERV_NAME}"
    echo "  IP        : ${ip_wserv:-non trouvée}"
    echo "  Port HTTP : 80"
    echo "  Port WinRM: 5985"
    echo "  AD DNS    : ${WINDOWS_DOMAIN_NAME}"
    echo "  AD NetBIOS: ${WINDOWS_DOMAIN_NETBIOS}"
    [[ -n "$ip_wserv" ]] && echo "  URL       : http://${ip_wserv}"
    echo "  Login     : ${WSERV_ADMIN_USER} / ${WSERV_ADMIN_PASSWORD}"
  fi

  if [[ "$DEPLOY_AD" == "1" ]]; then
    local ip_dc=""
    pushd terraform >/dev/null 2>&1
    ip_dc="$(resolve_container_ip "$AD_DC_NAME" 2>/dev/null || true)"
    popd >/dev/null 2>&1
    echo ""
    echo -e "${BOLD}Active Directory (Samba DC)${NC}"
    echo "  Container : ${VM_PREFIX}-${AD_DC_NAME}"
    echo "  IP        : ${ip_dc:-non trouvée}"
    echo "  LDAP      : ldap://${ip_dc:-<ip>}"
    echo "  Kerberos  : ${ip_dc:-<ip>}:88"
    echo "  Domaine   : (voir ansible/vars/ad_config.yml)"
    echo "  Login DC  : ${CI_USER} / ${CI_PASSWORD}"
    echo "  Admin AD  : Administrator / (voir ansible/vars/ad_config.yml)"
    echo "  Config OUs/GPOs : ansible/vars/ad_config.yml"
  fi
  echo ""
}

provision_windows_after_apply() {
  if [[ "$DEPLOY_WSERV" != "1" ]]; then
    return 0
  fi

  if [[ $EUID -eq 0 ]] && command -v qm >/dev/null 2>&1; then
    if qm status "$WSERV_VM_ID" 2>/dev/null | grep -q "stopped"; then
      log_warn "VM Windows ${WSERV_VM_ID} arrêtée après apply, démarrage forcé..."
      qm start "$WSERV_VM_ID" || true
      sleep 5
    fi
  fi

  local wip="${WSERV_RESOLVED_IP:-}"
  if [[ -z "$wip" ]]; then
    if ! wait_for_windows_ip; then
      log_warn "IP Windows non trouvée, provisioning Windows ignoré."
      return 0
    fi
    wip="${WSERV_RESOLVED_IP:-}"
  fi

  log_ok "IP Windows détectée: $wip"

  log_title "Provisionnement Windows"
  if [[ -x "./scripts/provision_windows.sh" ]]; then
    ./scripts/provision_windows.sh "${VM_PREFIX}-${WSERV_NAME}" "$wip" "./ansible/playbooks/install_wserv.yml" "$WSERV_ADMIN_USER" "$WSERV_ADMIN_PASSWORD" "$WINDOWS_DOMAIN_NAME" "$WINDOWS_DOMAIN_NETBIOS" "$WINDOWS_SAFE_MODE_PASSWORD" "$AD_OU_LIST" "$AD_GROUP_LIST" "$AD_USER_LIST" "$AD_DEFAULT_USER_PASSWORD" || \
      log_warn "Provisioning Windows échoué (WinRM indisponible ou credentials invalides)."
  else
    log_warn "scripts/provision_windows.sh introuvable/exécutable."
  fi
}

main() {
  trap cleanup EXIT

  log_title "Préparation"
  need_cmd terraform
  need_cmd curl
  need_cmd ssh-keygen

  SSH_PUB_KEY="$(detect_or_create_ssh_key)"
  log_ok "SSH public key ready."

  prompt_deployment_plan_if_interactive
  validate_windows_plan
  if [[ "$DEPLOY_WSERV" == "1" ]]; then
    log_info "wSERV sélectionné."
  fi

  log_title "Validation Auth Proxmox"
  if [[ "$PROXMOX_AUTH_PREFERENCE" == "token" ]]; then
    log_info "Authentification préférée: API token"
    if [[ -z "$PROXMOX_TOKEN_ID" || -z "$PROXMOX_TOKEN_SECRET" ]]; then
      log_info "Creating Proxmox token automatically..."
      if setup_token_when_possible; then
        log_ok "Token created: ${PROXMOX_TOKEN_ID}"
      else
        log_warn "Token auto-creation unavailable, fallback to password."
      fi
    fi

    if [[ -n "$PROXMOX_TOKEN_ID" && -n "$PROXMOX_TOKEN_SECRET" ]] && token_has_provider_level_access && token_has_vm_monitor_access; then
      AUTH_MODE_SELECTED="token"
      log_ok "Token auth validated with VM.Monitor access."
    else
      log_warn "Token auth invalid ou permissions insuffisantes."
    fi
  fi

  if [[ -z "$AUTH_MODE_SELECTED" ]]; then
    # Fallback password uniquement si explicitement fourni (pas d'invite interactive).
    if [[ -n "${PROXMOX_PASSWORD:-}" && "${PROXMOX_PASSWORD}" != "ton_mdp" ]]; then
      if [[ $EUID -eq 0 ]] && command -v pveum >/dev/null 2>&1; then
        pveum aclmod / -user "$PROXMOX_USER" -role Administrator >/dev/null 2>&1 || true
      fi
      if password_has_provider_level_access && password_has_vm_monitor_access; then
        AUTH_MODE_SELECTED="password"
        PROXMOX_TOKEN_ID=""
        PROXMOX_TOKEN_SECRET=""
        log_ok "Password auth validated with VM.Monitor access."
      fi
    fi

    if [[ -z "$AUTH_MODE_SELECTED" ]]; then
      log_err "Authentification Proxmox impossible sans prompt. Fournis un token valide, ou PROXMOX_PASSWORD en variable d'environnement."
      exit 1
    fi
  fi

  log_title "Génération Config"
  write_env_file
  write_tfvars
  if [[ "$AUTH_MODE_SELECTED" == "password" ]]; then
    log_info "Auth Terraform: password (${PROXMOX_USER})"
  else
    log_info "Auth Terraform: token (${PROXMOX_TOKEN_ID})"
  fi

  if run_terraform; then
    provision_windows_after_apply
    log_ok "Deployment complete."
    print_service_urls
  else
    log_err "terraform apply failed after ${MAX_APPLY_ATTEMPTS} attempts."
    exit 1
  fi
}

main "$@"
