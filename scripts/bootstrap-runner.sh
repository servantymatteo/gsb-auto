#!/bin/bash
set -euo pipefail

# --- Configurable vars (override via env) ---
VM_ID="${VM_ID:-9001}"
VM_NAME="${VM_NAME:-terraform-runner}"
TARGET_NODE="${TARGET_NODE:-$(hostname)}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-2}"
MEMORY_MB="${MEMORY_MB:-4096}"
DISK_GB="${DISK_GB:-20}"
CI_USER="${CI_USER:-terraform}"
CI_PASSWORD="${CI_PASSWORD:-Formation13@}"
IP_CONFIG="${IP_CONFIG:-ip=dhcp}"
IMAGE_URL="${IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2}"
IMAGE_FILE="${IMAGE_FILE:-/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2}"
SSH_PUB_KEY_FILE="${SSH_PUB_KEY_FILE:-}" # optional explicit path
DESTROY_IF_EXISTS="${DESTROY_IF_EXISTS:-1}"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Commande manquante: $1"; exit 1; }
}

find_ssh_pubkey() {
  if [[ -n "$SSH_PUB_KEY_FILE" && -f "$SSH_PUB_KEY_FILE" ]]; then
    cat "$SSH_PUB_KEY_FILE"; return 0
  fi

  if [[ -f "./ssh/id_ed25519_terraform.pub" ]]; then
    cat "./ssh/id_ed25519_terraform.pub"; return 0
  fi

  if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    cat "$HOME/.ssh/id_ed25519.pub"; return 0
  fi

  if [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
    cat "$HOME/.ssh/id_rsa.pub"; return 0
  fi

  return 1
}

main() {
  need_cmd qm
  need_cmd wget
  need_cmd awk

  if [[ $EUID -ne 0 ]]; then
    err "Ce script doit être exécuté en root sur Proxmox."
    exit 1
  fi

  echo -e "\n${BOLD}=== Bootstrap VM Terraform Runner ===${NC}"

  SSH_PUB_KEY="$(find_ssh_pubkey || true)"
  if [[ -z "$SSH_PUB_KEY" ]]; then
    err "Aucune clé SSH publique trouvée. Fournis SSH_PUB_KEY_FILE=/chemin/cle.pub"
    exit 1
  fi
  ok "Clé SSH détectée"

  if [[ ! -f "$IMAGE_FILE" ]]; then
    log "Téléchargement de l'image cloud Debian..."
    mkdir -p "$(dirname "$IMAGE_FILE")"
    wget -O "$IMAGE_FILE" "$IMAGE_URL"
  else
    ok "Image cloud déjà présente: $IMAGE_FILE"
  fi

  if qm status "$VM_ID" >/dev/null 2>&1; then
    if [[ "$DESTROY_IF_EXISTS" == "1" ]]; then
      warn "VM $VM_ID existe déjà, suppression..."
      qm stop "$VM_ID" >/dev/null 2>&1 || true
      qm destroy "$VM_ID" --purge
    else
      err "VM $VM_ID existe déjà. Mets DESTROY_IF_EXISTS=1 pour remplacer."
      exit 1
    fi
  fi

  log "Création de la VM $VM_ID ($VM_NAME)..."
  qm create "$VM_ID" \
    --name "$VM_NAME" \
    --node "$TARGET_NODE" \
    --memory "$MEMORY_MB" \
    --cores "$CORES" \
    --net0 "virtio,bridge=$BRIDGE" \
    --agent 1 \
    --scsihw virtio-scsi-pci \
    --ostype l26

  log "Import du disque cloud image..."
  qm importdisk "$VM_ID" "$IMAGE_FILE" "$STORAGE"

  # local-lvm pattern
  qm set "$VM_ID" --scsi0 "$STORAGE:vm-${VM_ID}-disk-0" || qm set "$VM_ID" --scsi0 "$STORAGE:0,import-from=$IMAGE_FILE"

  qm set "$VM_ID" --ide2 "$STORAGE:cloudinit"
  qm set "$VM_ID" --boot c --bootdisk scsi0
  qm set "$VM_ID" --serial0 socket --vga serial0

  qm resize "$VM_ID" scsi0 "${DISK_GB}G" || true

  log "Configuration cloud-init..."
  qm set "$VM_ID" --ciuser "$CI_USER"
  qm set "$VM_ID" --cipassword "$CI_PASSWORD"
  qm set "$VM_ID" --ipconfig0 "$IP_CONFIG"
  local ssh_tmp
  ssh_tmp="$(mktemp)"
  printf "%s\n" "$SSH_PUB_KEY" > "$ssh_tmp"
  qm set "$VM_ID" --sshkeys "$ssh_tmp"
  rm -f "$ssh_tmp"

  log "Démarrage VM..."
  qm start "$VM_ID"

  ok "VM runner prête."
  echo ""
  echo "Actions suivantes:"
  echo "1) Récupérer l'IP (GUI Proxmox ou 'qm guest cmd $VM_ID network-get-interfaces' si qemu-guest-agent actif)"
  echo "2) SSH: ssh ${CI_USER}@<IP_VM>"
  echo "3) Dans la VM:"
  echo "   sudo apt update && sudo apt install -y git curl"
  echo "   git clone https://github.com/servantymatteo/gsb-auto.git && cd gsb-auto && ./setup.sh"
}

main "$@"
