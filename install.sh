#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/servantymatteo/gsb-auto/archive/refs/heads/main.tar.gz"
INSTALL_DIR="/opt/gsb-auto"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

LOG_FILE="/tmp/gsb-install-$$.log"
_SPINNER_PID=""
_SPINNER_MSG=""

log_ok()  { echo -e "  ${GREEN}✓${NC} $*"; }
log_err() { echo -e "  ${RED}✗${NC} $*"; }

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
    [[ -s "$LOG_FILE" ]] && tail -10 "$LOG_FILE" | sed 's/^/    /'
  fi
}

run_step() {
  local msg="$1"; shift
  start_spinner "$msg"
  if "$@" >>"$LOG_FILE" 2>&1; then
    stop_spinner 0
  else
    stop_spinner 1
    exit 1
  fi
}

install_terraform() {
  if command -v terraform >/dev/null 2>&1; then
    local ver
    ver="$(terraform version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    log_ok "Terraform déjà installé (v${ver})"
    return 0
  fi

  run_step "Installation Terraform..." bash -c '
    apt-get install -y gnupg lsb-release wget
    wget -qO- https://apt.releases.hashicorp.com/gpg \
      | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/hashicorp.list
    apt-get update -qq
    apt-get install -y terraform
  '
}

install_ansible() {
  if command -v ansible-playbook >/dev/null 2>&1; then
    log_ok "Ansible déjà installé"
    return 0
  fi
  run_step "Installation Ansible..." apt-get install -y ansible
}

main() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║        GSB Auto — Installation           ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo ""

  if [[ $EUID -ne 0 ]]; then
    log_err "Ce script doit être exécuté en root (sudo ou root)."
    exit 1
  fi

  run_step "Mise à jour des paquets..." apt-get update -qq
  run_step "Installation curl, tar, python3-pip..." apt-get install -y curl tar python3-pip

  install_terraform
  install_ansible

  run_step "Téléchargement gsb-auto..." bash -c "
    rm -rf '${INSTALL_DIR}'
    mkdir -p '${INSTALL_DIR}'
    curl -fsSL '${REPO_URL}' | tar -xz --strip-components=1 -C '${INSTALL_DIR}'
  "
  log_ok "Installé dans ${INSTALL_DIR}"

  chmod +x "$INSTALL_DIR/setup.sh"
  cd "$INSTALL_DIR"
  echo ""
  exec ./setup.sh
}

main "$@"
