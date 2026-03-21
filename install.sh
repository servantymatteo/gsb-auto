#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/servantymatteo/gsb-auto/archive/refs/heads/main.tar.gz"
INSTALL_DIR="/opt/gsb-auto"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*"; }

install_terraform() {
  if command -v terraform >/dev/null 2>&1; then
    log_ok "Terraform déjà installé ($(terraform version -json 2>/dev/null | grep -o '"[0-9.]*"' | head -1 || terraform version | head -1))"
    return 0
  fi

  log_info "Installation de Terraform..."
  apt-get install -y gnupg lsb-release wget >/dev/null

  wget -qO- https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list

  apt-get update -qq >/dev/null
  apt-get install -y terraform >/dev/null
  log_ok "Terraform installé."
}

install_ansible() {
  if command -v ansible-playbook >/dev/null 2>&1; then
    log_ok "Ansible déjà installé."
    return 0
  fi

  log_info "Installation d'Ansible..."
  apt-get install -y ansible >/dev/null
  log_ok "Ansible installé."
}

main() {
  echo -e "\n${BOLD}=== GSB Auto - Installation ===${NC}\n"

  if [[ $EUID -ne 0 ]]; then
    log_err "Ce script doit être exécuté en root."
    exit 1
  fi

  log_info "Mise à jour des paquets..."
  apt-get update -qq >/dev/null
  apt-get install -y curl tar >/dev/null

  install_terraform
  install_ansible

  log_info "Téléchargement de gsb-auto..."
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  curl -fsSL "$REPO_URL" | tar -xz --strip-components=1 -C "$INSTALL_DIR"
  log_ok "Repo téléchargé dans $INSTALL_DIR"

  chmod +x "$INSTALL_DIR/setup.sh"
  cd "$INSTALL_DIR"

  echo ""
  exec ./setup.sh
}

main "$@"
