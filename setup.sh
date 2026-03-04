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
    if [[ -t 0 ]]; then
      read -r -s -p "Mot de passe Proxmox pour ${PROXMOX_USER}: " PROXMOX_PASSWORD
      echo ""
    else
      log_err "Mot de passe Proxmox manquant. Lance en interactif ou exporte PROXMOX_PASSWORD."
      exit 1
    fi
  fi
}

MAX_APPLY_ATTEMPTS="${MAX_APPLY_ATTEMPTS:-3}"
CLEANUP_AT_END="${CLEANUP_AT_END:-1}"
VM_PREFIX="${VM_PREFIX:-GSB}"
TARGET_NODE="${TARGET_NODE:-$(hostname)}"
PROXMOX_API_URL="${PROXMOX_API_URL:-https://127.0.0.1:8006/api2/json}"
TEMPLATE_NAME="${TEMPLATE_NAME:-debian-12-standard_12.12-1_amd64.tar.zst}"
VM_STORAGE="${VM_STORAGE:-local-lvm}"
CI_USER="${CI_USER:-root}"
CI_PASSWORD="${CI_PASSWORD:-Formation13@}"
TOKEN_USER="${TOKEN_USER:-terraform-prov@pve}"
TOKEN_NAME="${TOKEN_NAME:-auto-token}"
PROXMOX_TOKEN_PRIVSEP="${PROXMOX_TOKEN_PRIVSEP:-0}"
PROXMOX_USER="${PROXMOX_USER:-root@pam}"
PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-}"
PROXMOX_AUTH_PREFERENCE="password"

DEPLOY_APACHE="${DEPLOY_APACHE:-1}"
DEPLOY_GLPI="${DEPLOY_GLPI:-1}"
DEPLOY_UPTIME="${DEPLOY_UPTIME:-1}"

SSH_PUB_KEY=""
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-}"
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"
AUTH_MODE_SELECTED=""

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

cleanup() {
  if [[ "$CLEANUP_AT_END" != "1" ]]; then
    return 0
  fi

  rm -f .env.local
  rm -f terraform/terraform.tfvars
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
  "web" = {
    cores     = 2
    memory    = 2048
    disk_size = "10G"
    playbook  = "install_apache.yml"
  }
EOF
  fi

  if [[ "$DEPLOY_GLPI" == "1" ]]; then
    cat >> terraform/terraform.tfvars <<EOF
  "glpi" = {
    cores     = 2
    memory    = 4096
    disk_size = "20G"
    playbook  = "install_glpi.yml"
  }
EOF
  fi

  if [[ "$DEPLOY_UPTIME" == "1" ]]; then
    cat >> terraform/terraform.tfvars <<EOF
  "monitoring" = {
    cores     = 2
    memory    = 2048
    disk_size = "15G"
    playbook  = "install_uptime_kuma.yml"
  }
EOF
  fi

  cat >> terraform/terraform.tfvars <<EOF
}
EOF
}

run_terraform() {
  # Empêche les variables d'environnement Proxmox de surcharger le mode d'auth choisi.
  unset PM_API_TOKEN_ID PM_API_TOKEN_SECRET PM_USER PM_PASS PM_PASSWORD
  unset PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET

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
  echo "Services:"
  local ip_web ip_glpi ip_uptime
  pushd terraform >/dev/null
  ip_web="$(terraform state show 'proxmox_lxc.container["web"]' 2>/dev/null | grep "ipv4_addresses" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true)"
  ip_glpi="$(terraform state show 'proxmox_lxc.container["glpi"]' 2>/dev/null | grep "ipv4_addresses" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true)"
  ip_uptime="$(terraform state show 'proxmox_lxc.container["monitoring"]' 2>/dev/null | grep "ipv4_addresses" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true)"
  popd >/dev/null

  [[ -n "$ip_web" ]] && echo "- Apache: http://$ip_web"
  [[ -n "$ip_glpi" ]] && echo "- GLPI: http://$ip_glpi/glpi (glpi / glpi)"
  [[ -n "$ip_uptime" ]] && echo "- Uptime Kuma: http://$ip_uptime:3001"
}

main() {
  trap cleanup EXIT

  log_title "Préparation"
  need_cmd terraform
  need_cmd curl
  need_cmd ssh-keygen

  SSH_PUB_KEY="$(detect_or_create_ssh_key)"
  log_ok "SSH public key ready."

  log_title "Validation Auth Proxmox"
  prompt_password_if_missing
  if [[ $EUID -eq 0 ]] && command -v pveum >/dev/null 2>&1; then
    pveum aclmod / -user "$PROXMOX_USER" -role Administrator >/dev/null 2>&1 || true
  fi
  if password_has_provider_level_access && password_has_vm_monitor_access; then
    AUTH_MODE_SELECTED="password"
    PROXMOX_TOKEN_ID=""
    PROXMOX_TOKEN_SECRET=""
    log_ok "Password auth validated with VM.Monitor access."
  else
    log_err "Password auth failed (provider or VM.Monitor access missing)."
    exit 1
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
    log_ok "Deployment complete."
    print_service_urls
  else
    log_err "terraform apply failed after ${MAX_APPLY_ATTEMPTS} attempts."
    exit 1
  fi
}

main "$@"
