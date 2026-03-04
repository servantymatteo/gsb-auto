#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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

DEPLOY_APACHE="${DEPLOY_APACHE:-1}"
DEPLOY_GLPI="${DEPLOY_GLPI:-1}"
DEPLOY_UPTIME="${DEPLOY_UPTIME:-1}"

SSH_PUB_KEY=""
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-}"
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"
AUTO_TOKEN_CREATED=0

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] Command not found: $1"
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

  # Mode le plus robuste: token root@pam sans séparation de privilèges.
  TOKEN_USER="${PROXMOX_USER}"
  if [[ "$TOKEN_USER" != *"@"* ]]; then
    TOKEN_USER="root@pam"
  fi

  pveum user token delete "$TOKEN_USER" "$TOKEN_NAME" >/dev/null 2>&1 || true
  local token_output
  token_output="$(pveum user token add "$TOKEN_USER" "$TOKEN_NAME" --privsep 0 --output-format json)"

  PROXMOX_TOKEN_ID="${TOKEN_USER}!${TOKEN_NAME}"
  PROXMOX_TOKEN_SECRET="$(echo "$token_output" | sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  AUTO_TOKEN_CREATED=1

  if [[ -z "$PROXMOX_TOKEN_SECRET" ]]; then
    echo "[ERROR] Failed to create Proxmox API token secret."
    exit 1
  fi
}

token_has_provider_level_access() {
  local base_url status
  base_url="${PROXMOX_API_URL%/api2/json}"
  status="$(curl -k -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
    "${base_url}/api2/json/access/users")"
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

cleanup() {
  if [[ "$CLEANUP_AT_END" != "1" ]]; then
    return 0
  fi

  rm -f .env.local
  rm -f terraform/terraform.tfvars

  if [[ $AUTO_TOKEN_CREATED -eq 1 && $EUID -eq 0 ]] && command -v pveum >/dev/null 2>&1; then
    pveum user token delete "$TOKEN_USER" "$TOKEN_NAME" >/dev/null 2>&1 || true
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
  cat > terraform/terraform.tfvars <<EOF
pm_api_url = "$PROXMOX_API_URL"
pm_api_token_id     = "$PROXMOX_TOKEN_ID"
pm_api_token_secret = "$PROXMOX_TOKEN_SECRET"
pm_user             = "$PROXMOX_USER"
pm_password         = "$PROXMOX_PASSWORD"

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
  pushd terraform >/dev/null
  TF_IN_AUTOMATION=1 terraform init -input=false -compact-warnings

  local attempt
  for attempt in $(seq 1 "$MAX_APPLY_ATTEMPTS"); do
    echo "[INFO] terraform apply attempt ${attempt}/${MAX_APPLY_ATTEMPTS}"
    if TF_IN_AUTOMATION=1 terraform apply --auto-approve -compact-warnings; then
      popd >/dev/null
      return 0
    fi
    if [[ "$attempt" -lt "$MAX_APPLY_ATTEMPTS" ]]; then
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

  need_cmd terraform
  need_cmd curl
  need_cmd ssh-keygen

  SSH_PUB_KEY="$(detect_or_create_ssh_key)"
  echo "[INFO] SSH public key ready."

  if [[ -z "$PROXMOX_TOKEN_ID" || -z "$PROXMOX_TOKEN_SECRET" ]]; then
    echo "[INFO] Creating Proxmox token automatically..."
    if ! setup_token_when_possible; then
      echo "[ERROR] Could not auto-create token. Export PROXMOX_TOKEN_ID and PROXMOX_TOKEN_SECRET, or run as root on Proxmox host."
      exit 1
    fi
  fi

  if ! token_has_provider_level_access; then
    echo "[WARN] Token valid but insufficient for provider checks. Switching to password auth."
    PROXMOX_TOKEN_ID=""
    PROXMOX_TOKEN_SECRET=""
    if [[ -z "$PROXMOX_PASSWORD" && -t 0 ]]; then
      read -r -s -p "Proxmox password for ${PROXMOX_USER}: " PROXMOX_PASSWORD
      echo ""
    fi
    if [[ -z "$PROXMOX_PASSWORD" ]] || ! password_has_provider_level_access; then
      echo "[ERROR] Password fallback failed. Set PROXMOX_PASSWORD and retry."
      exit 1
    fi
  fi

  write_env_file
  write_tfvars

  if run_terraform; then
    echo "[OK] Deployment complete."
    print_service_urls
  else
    echo "[ERROR] terraform apply failed after ${MAX_APPLY_ATTEMPTS} attempts."
    exit 1
  fi
}

main "$@"
