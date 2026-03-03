#!/bin/bash

set -euo pipefail

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

success() { echo -e "${GREEN}✓ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}" >&2; exit "${2:-1}"; }
info() { echo -e "${CYAN}→ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

is_ephemeral_dir() {
    case "$1" in
        /tmp/*|/private/tmp/*|/var/folders/*/T/*|/dev/fd|/dev/fd/*|/proc/self/fd|/proc/self/fd/*) return 0 ;;
        *) return 1 ;;
    esac
}

sync_project_repo() {
    info "Synchronisation du projet (${REPO_BRANCH}) dans ${INSTALL_DIR}..."

    if [ ! -d "$INSTALL_DIR/.git" ]; then
        mkdir -p "$(dirname "$INSTALL_DIR")"
        git clone -b "$REPO_BRANCH" "$GITHUB_REPO" "$INSTALL_DIR" >/dev/null \
          || error "Clone du dépôt impossible: $GITHUB_REPO"
        success "Projet cloné dans $INSTALL_DIR"
        return 0
    fi

    if ! git -C "$INSTALL_DIR" fetch origin "$REPO_BRANCH" >/dev/null 2>&1; then
        warning "Impossible de récupérer origin/${REPO_BRANCH}. Utilisation de la version locale."
        return 0
    fi

    local local_head remote_head
    local_head="$(git -C "$INSTALL_DIR" rev-parse HEAD)"
    remote_head="$(git -C "$INSTALL_DIR" rev-parse "origin/${REPO_BRANCH}")"

    if [ "$local_head" = "$remote_head" ]; then
        success "Projet déjà à jour (${local_head:0:7})"
        return 0
    fi

    if git -C "$INSTALL_DIR" merge-base --is-ancestor "$local_head" "$remote_head"; then
        git -C "$INSTALL_DIR" checkout "$REPO_BRANCH" >/dev/null 2>&1 || true
        git -C "$INSTALL_DIR" pull --ff-only origin "$REPO_BRANCH" >/dev/null \
          || error "Mise à jour du dépôt impossible (ff-only)."
        success "Projet mis à jour ${local_head:0:7} -> ${remote_head:0:7}"
    else
        warning "Le dépôt local diverge de origin/${REPO_BRANCH}; aucune fusion auto."
        warning "Dépôt utilisé tel quel: $INSTALL_DIR"
    fi
}

clean_install_dir_before_sync() {
    if [ "${CLEAN_BEFORE_SYNC:-1}" != "1" ]; then
        return 0
    fi

    # Ne jamais nettoyer le dossier d'exécution courant (mode repo local)
    if [ "$SCRIPT_DIR" = "$INSTALL_DIR" ]; then
        return 0
    fi

    if [ ! -e "$INSTALL_DIR" ]; then
        return 0
    fi

    info "Nettoyage de l'ancienne installation dans ${INSTALL_DIR}..."

    if [ -d "$INSTALL_DIR/.git" ]; then
        # Nettoyage complet d'un ancien clone
        git -C "$INSTALL_DIR" fetch origin "$REPO_BRANCH" >/dev/null 2>&1 || true
        git -C "$INSTALL_DIR" checkout "$REPO_BRANCH" >/dev/null 2>&1 || true
        git -C "$INSTALL_DIR" reset --hard "origin/$REPO_BRANCH" >/dev/null 2>&1 || true
        git -C "$INSTALL_DIR" clean -fdx >/dev/null 2>&1 || true
    else
        rm -rf "$INSTALL_DIR"
    fi

    success "Nettoyage terminé"
}

clear
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║    AUTO GSB - Bootstrap Proxmox               ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
echo ""

if [ ! -f "/etc/pve/.version" ]; then
    error "Ce script doit être exécuté sur un serveur Proxmox."
fi

success "Serveur Proxmox détecté"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_REPO="${GITHUB_REPO:-https://github.com/servantymatteo/gsb-auto.git}"
REPO_BRANCH="${REPO_BRANCH:-local}"
if [ -z "${INSTALL_DIR:-}" ]; then
    if is_ephemeral_dir "$SCRIPT_DIR"; then
        INSTALL_DIR="$HOME/gsb-auto"
    else
        INSTALL_DIR="$SCRIPT_DIR"
    fi
fi

command -v git >/dev/null 2>&1 || error "git est requis pour synchroniser le projet."
clean_install_dir_before_sync
sync_project_repo

if [ "${INSTALL_BOOTSTRAPPED:-0}" != "1" ] && [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
    info "Relance du script depuis ${INSTALL_DIR}..."
    exec env \
      INSTALL_BOOTSTRAPPED=1 \
      INSTALL_DIR="$INSTALL_DIR" \
      GITHUB_REPO="$GITHUB_REPO" \
      REPO_BRANCH="$REPO_BRANCH" \
      bash "$INSTALL_DIR/install.sh" "$@"
fi

# CT outils
TOOLS_CT_NAME="${TOOLS_CT_NAME:-auto-gsb-tools}"
TOOLS_CT_STORAGE="${TOOLS_CT_STORAGE:-local-lvm}"
TOOLS_CT_BRIDGE="${TOOLS_CT_BRIDGE:-vmbr0}"
TOOLS_CT_ROOTFS="${TOOLS_CT_ROOTFS:-8}"
TOOLS_CT_CORES="${TOOLS_CT_CORES:-2}"
TOOLS_CT_MEMORY="${TOOLS_CT_MEMORY:-2048}"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.7.0}"

find_latest_debian12_template() {
    pveam available --section system 2>/dev/null | awk '/debian-12-standard/ {print $2}' | tail -1
}

ensure_lxc_template() {
    local template_file=""
    template_file="$(find_latest_debian12_template)"

    if [ -z "$template_file" ]; then
        info "Mise à jour du catalogue des templates LXC..."
        pveam update >/dev/null
        template_file="$(find_latest_debian12_template)"
    fi

    if [ -z "$template_file" ]; then
        error "Impossible de trouver un template Debian 12 (debian-12-standard)."
    fi

    local template_path="/var/lib/vz/template/cache/${template_file}"
    if [ ! -f "$template_path" ]; then
        info "Téléchargement du template ${template_file}..."
        pveam download local "$template_file" >/dev/null
        success "Template Debian 12 téléchargé"
    else
        success "Template Debian 12 déjà présent (${template_file})"
    fi

    LXC_TEMPLATE_FILE="$template_file"
}

wait_for_ct() {
    local ctid="$1"
    local attempts=30

    for _ in $(seq 1 "$attempts"); do
        if pct exec "$ctid" -- true >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

install_tools_in_ct() {
    local existing_id=""
    existing_id="$(pct list 2>/dev/null | awk -v name="$TOOLS_CT_NAME" '$3==name {print $1; exit}')"

    local ctid="${TOOLS_CT_ID:-}"
    if [ -z "$ctid" ] && [ -n "$existing_id" ]; then
        ctid="$existing_id"
    fi
    if [ -z "$ctid" ]; then
        ctid="$(pvesh get /cluster/nextid)"
    fi

    local template_file
    ensure_lxc_template
    template_file="$LXC_TEMPLATE_FILE"

    if pct status "$ctid" >/dev/null 2>&1; then
        success "CT outils détecté (ID: $ctid)"
    else
        info "Création du CT outils ${TOOLS_CT_NAME} (ID: $ctid)..."
        pct create "$ctid" "local:vztmpl/${template_file}" \
          --hostname "$TOOLS_CT_NAME" \
          --cores "$TOOLS_CT_CORES" \
          --memory "$TOOLS_CT_MEMORY" \
          --rootfs "${TOOLS_CT_STORAGE}:${TOOLS_CT_ROOTFS}" \
          --unprivileged 1 \
          --onboot 1 \
          --features nesting=1 \
          --net0 "name=eth0,bridge=${TOOLS_CT_BRIDGE},ip=dhcp" >/dev/null
        success "CT créé"
    fi

    pct start "$ctid" >/dev/null 2>&1 || true

    info "Initialisation du CT outils..."
    if ! wait_for_ct "$ctid"; then
        error "Le CT $ctid ne répond pas à temps."
    fi

    info "Installation Ansible/Git/Curl/Unzip dans le CT..."
    pct exec "$ctid" -- bash -lc "export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null && apt-get install -y ansible git curl unzip ca-certificates >/dev/null"

    info "Installation Terraform ${TERRAFORM_VERSION} dans le CT..."
    pct exec "$ctid" -- bash -lc "
        if ! command -v terraform >/dev/null 2>&1; then
            cd /tmp
            curl -fsSLO https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip
            unzip -o terraform_${TERRAFORM_VERSION}_linux_amd64.zip >/dev/null
            install -m 0755 terraform /usr/local/bin/terraform
            rm -f terraform terraform_${TERRAFORM_VERSION}_linux_amd64.zip
        fi
    "

    info "Préparation du projet dans le CT..."
    pct exec "$ctid" -- bash -lc "
        if [ -d /opt/auto_gsb/.git ]; then
            cd /opt/auto_gsb && \
            git fetch origin '${REPO_BRANCH}' >/dev/null 2>&1 || true && \
            git checkout '${REPO_BRANCH}' >/dev/null 2>&1 || true && \
            git pull --ff-only origin '${REPO_BRANCH}' >/dev/null || true
        else
            git clone -b '${REPO_BRANCH}' '$GITHUB_REPO' /opt/auto_gsb >/dev/null
        fi
    "

    success "CT outils prêt"
    echo ""
    echo -e "${GREEN}Utilisation du CT outils:${NC}"
    echo -e "  ${YELLOW}pct enter ${ctid}${NC}"
    echo -e "  ${YELLOW}cd /opt/auto_gsb${NC}"
    echo -e "  ${YELLOW}cp .env.local.example .env.local${NC}"
    echo -e "  ${YELLOW}nano .env.local${NC}"
    echo -e "  ${YELLOW}./setup.sh${NC}"
    echo ""
}

terraform_ok=true
ansible_ok=true

if ! command -v terraform >/dev/null 2>&1; then
    terraform_ok=false
fi
if ! command -v ansible-playbook >/dev/null 2>&1; then
    ansible_ok=false
fi

if $terraform_ok && $ansible_ok; then
    success "Terraform et Ansible sont déjà installés sur l'hôte"
    read -r -p "Voulez-vous utiliser l'hôte Proxmox pour lancer les déploiements ? (O/n): " USE_HOST
    USE_HOST="${USE_HOST:-O}"

    if [[ ! "$USE_HOST" =~ ^[oOyY]$ ]]; then
        install_tools_in_ct
        exit 0
    fi
else
    missing=()
    $terraform_ok || missing+=("Terraform")
    $ansible_ok || missing+=("Ansible")
    warning "Outils manquants sur l'hôte: ${missing[*]}"
    read -r -p "Installer les outils dans un CT dédié ? (O/n): " CREATE_TOOLS_CT
    CREATE_TOOLS_CT="${CREATE_TOOLS_CT:-O}"

    if [[ "$CREATE_TOOLS_CT" =~ ^[oOyY]$ ]]; then
        install_tools_in_ct
        exit 0
    fi

    error "Installation interrompue. Les déploiements nécessitent Terraform + Ansible."
fi

if [ ! -f "$INSTALL_DIR/.env.local" ] && [ -f "$INSTALL_DIR/.env.local.example" ]; then
    cp "$INSTALL_DIR/.env.local.example" "$INSTALL_DIR/.env.local"
    warning "Fichier .env.local créé depuis .env.local.example (à compléter)"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         INSTALLATION TERMINÉE ✓               ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Prochaines étapes:${NC}"
echo -e "  ${YELLOW}cd $INSTALL_DIR${NC}"
echo -e "  ${YELLOW}nano .env.local${NC}"
echo -e "  ${YELLOW}./setup.sh${NC}"
echo ""
