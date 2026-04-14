#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

VM_NAME="$1"
VM_IP="$2"
PLAYBOOK="$3"
WIN_USER="$4"
WIN_PASSWORD="$5"
AD_DOMAIN_NAME="${6:-gsb.local}"
AD_DOMAIN_NETBIOS="${7:-GSB}"
AD_SAFE_MODE_PASSWORD="${8:-Formation13@}"
AD_OU_LIST="${9:-}"
AD_GROUP_LIST="${10:-}"
AD_USER_LIST="${11:-}"
AD_DEFAULT_USER_PASSWORD="${12:-Formation13@}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_CONFIG="$PROJECT_ROOT/ansible/ansible.cfg"
LOG_FILE="/tmp/gsb-ansible-$$.log"

log_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
log_warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
log_err()  { echo -e "  ${RED}✗${NC} $*"; }

_SPINNER_PID=""
_SPINNER_MSG=""

_spinner_loop() {
  local msg="$1"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while true; do
    printf "\r  \033[0;36m${frames[$i]}\033[0m %s" "$msg"
    i=$(( (i + 1) % 10 ))
    sleep 0.08
  done
}

start_spinner() {
  _SPINNER_MSG="$1"
  _spinner_loop "$1" &
  _SPINNER_PID=$!
  disown "$_SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
  local status="${1:-0}"
  if [[ -n "$_SPINNER_PID" ]]; then
    kill "$_SPINNER_PID" 2>/dev/null || true
    _SPINNER_PID=""
    printf "\r\033[K"
  fi
  if [[ "$status" == "0" ]]; then
    echo -e "  ${GREEN}✓${NC} ${_SPINNER_MSG}"
  else
    echo -e "  ${RED}✗${NC} ${_SPINNER_MSG}"
    if [[ -s "$LOG_FILE" ]]; then
      echo -e "  ${DIM}--- dernières lignes ---${NC}"
      grep -E "ERROR|FAILED|fatal|error" "$LOG_FILE" | tail -10 | sed 's/^/    /' || \
        tail -10 "$LOG_FILE" | sed 's/^/    /'
      echo -e "  ${DIM}--- log complet: ${LOG_FILE} ---${NC}"
    fi
  fi
}

if [[ -z "$VM_IP" ]]; then
  log_err "IP Windows introuvable"
  exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  log_err "ansible-playbook non installé"
  exit 1
fi

# ── Attente WinRM ────────────────────────────────────────────────────────
start_spinner "Attente WinRM sur ${VM_IP}:5985..."
connected=0
for i in $(seq 1 60); do
  if (echo > /dev/tcp/"$VM_IP"/5985) >/dev/null 2>&1; then
    connected=1
    break
  fi
  sleep 10
done

if [[ "$connected" == "0" ]]; then
  stop_spinner 1
  exit 1
fi
stop_spinner 0

# ── Ansible ──────────────────────────────────────────────────────────────
start_spinner "Configuration Windows (IIS, AD DS)..."

ANSIBLE_FORCE_COLOR=0 ANSIBLE_CONFIG="$ANSIBLE_CONFIG" ansible-playbook \
  -i "${VM_IP}," \
  "$PLAYBOOK" \
  -e "ansible_connection=winrm" \
  -e "ansible_port=5985" \
  -e "ansible_winrm_transport=basic" \
  -e "ansible_winrm_server_cert_validation=ignore" \
  -e "ansible_user=${WIN_USER}" \
  -e "ansible_password=${WIN_PASSWORD}" \
  -e "ad_domain_name=${AD_DOMAIN_NAME}" \
  -e "ad_domain_netbios=${AD_DOMAIN_NETBIOS}" \
  -e "ad_safe_mode_password=${AD_SAFE_MODE_PASSWORD}" \
  -e "ad_ou_list=${AD_OU_LIST}" \
  -e "ad_group_list=${AD_GROUP_LIST}" \
  -e "ad_user_list=${AD_USER_LIST}" \
  -e "ad_default_user_password=${AD_DEFAULT_USER_PASSWORD}" \
  >>"$LOG_FILE" 2>&1

ansible_status=$?
stop_spinner "$ansible_status"
exit "$ansible_status"
