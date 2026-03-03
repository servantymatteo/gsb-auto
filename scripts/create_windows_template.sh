#!/bin/bash
set -euo pipefail

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

if ! command -v qm >/dev/null 2>&1; then
    error "Ce script doit être lancé sur l'hôte Proxmox (commande 'qm' introuvable)."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [ -f ".env.local" ]; then
    # shellcheck disable=SC1091
    source ".env.local"
fi

TEMPLATE_NAME="${WINDOWS_TEMPLATE_ID:-WSERVER-TEMPLATE}"
SOURCE_VM_ID="${1:-}"
TARGET_NODE="${TARGET_NODE:-$(hostname)}"
VM_STORAGE="${VM_STORAGE:-local-lvm}"
WINDOWS_BUILD_BRIDGE="${WINDOWS_BUILD_BRIDGE:-vmbr0}"
WINDOWS_BUILD_VMID="${WINDOWS_BUILD_VMID:-}"
WINDOWS_BUILD_NAME="${WINDOWS_BUILD_NAME:-windows-template-build}"
WINDOWS_BUILD_CORES="${WINDOWS_BUILD_CORES:-2}"
WINDOWS_BUILD_MEMORY="${WINDOWS_BUILD_MEMORY:-4096}"
WINDOWS_BUILD_DISK_GB="${WINDOWS_BUILD_DISK_GB:-64}"
ISO_STORAGE_PATH="/var/lib/vz/template/iso"
WINDOWS_ISO_STORAGE="${WINDOWS_ISO_STORAGE:-local}"
AUTOUNATTEND_ISO_NAME="${AUTOUNATTEND_ISO_NAME:-autounattend.iso}"
AUTOUNATTEND_SOURCE_XML="$PROJECT_ROOT/docs/obsolete/autounattend.xml"

find_vmid_by_name() {
    local vm_name="$1"
    qm list 2>/dev/null | awk -v n="$vm_name" 'NR>1 && $2==n {print $1; exit}'
}

is_template_vmid() {
    local vmid="$1"
    qm config "$vmid" 2>/dev/null | grep -q '^template: 1$'
}

first_matching_iso() {
    local pattern="$1"
    ls -1 "$ISO_STORAGE_PATH"/*.iso 2>/dev/null | xargs -n1 basename 2>/dev/null | grep -Ei "$pattern" | head -1 || true
}

require_iso_tool() {
    if command -v genisoimage >/dev/null 2>&1; then
        echo "genisoimage"
    elif command -v mkisofs >/dev/null 2>&1; then
        echo "mkisofs"
    elif command -v xorriso >/dev/null 2>&1; then
        echo "xorriso -as mkisofs"
    else
        error "Aucun outil ISO trouvé (genisoimage/mkisofs/xorriso). Installe genisoimage."
    fi
}

ensure_autounattend_iso() {
    local iso_path="${ISO_STORAGE_PATH}/${AUTOUNATTEND_ISO_NAME}"
    [ -f "$iso_path" ] && return 0

    [ -f "$AUTOUNATTEND_SOURCE_XML" ] || error "Fichier source absent: $AUTOUNATTEND_SOURCE_XML"
    local iso_cmd
    iso_cmd="$(require_iso_tool)"
    local temp_dir
    temp_dir="$(mktemp -d)"
    cp "$AUTOUNATTEND_SOURCE_XML" "$temp_dir/autounattend.xml"

    info "Création de ${AUTOUNATTEND_ISO_NAME}..."
    eval "$iso_cmd -o \"$iso_path\" -J -R -V \"AUTOUNATTEND\" \"$temp_dir\"" >/dev/null 2>&1 || {
        rm -rf "$temp_dir"
        error "Échec création ISO autounattend."
    }
    rm -rf "$temp_dir"
    success "ISO autounattend créé: $iso_path"
}

wait_for_qga() {
    local vmid="$1"
    local max_attempts="${2:-180}" # 90 min (180 * 30s)
    local sleep_sec=30
    local i
    for i in $(seq 1 "$max_attempts"); do
        if qm agent "$vmid" ping >/dev/null 2>&1; then
            return 0
        fi
        if [ $((i % 10)) -eq 0 ]; then
            info "En attente QEMU Guest Agent ($i/$max_attempts)..."
        fi
        sleep "$sleep_sec"
    done
    return 1
}

guest_exec_ps() {
    local vmid="$1"
    local cmd="$2"
    qm guest exec "$vmid" -- powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$cmd" >/dev/null
}

wait_for_vm_stopped() {
    local vmid="$1"
    local max_attempts="${2:-90}" # 30 min (90 * 20s)
    local sleep_sec=20
    local i
    for i in $(seq 1 "$max_attempts"); do
        local state
        state="$(qm status "$vmid" | awk '{print $2}')"
        [ "$state" = "stopped" ] && return 0
        sleep "$sleep_sec"
    done
    return 1
}

auto_build_from_iso() {
    [ -d "$ISO_STORAGE_PATH" ] || error "Dossier ISO Proxmox introuvable: $ISO_STORAGE_PATH"

    local windows_iso="${WINDOWS_INSTALL_ISO:-$(first_matching_iso 'windows|server')}"
    local virtio_iso="${VIRTIO_ISO:-$(first_matching_iso 'virtio')}"

    if [ -z "$windows_iso" ]; then
        echo -e "${CYAN}ISOs disponibles:${NC}"
        ls -1 "$ISO_STORAGE_PATH"/*.iso 2>/dev/null | xargs -n1 basename || true
        echo ""
        read -r -p "Nom de l'ISO Windows (ex: windows-server-2022.iso): " windows_iso
    fi
    [ -f "$ISO_STORAGE_PATH/$windows_iso" ] || error "ISO Windows introuvable: $ISO_STORAGE_PATH/$windows_iso"

    if [ -z "$virtio_iso" ]; then
        echo -e "${YELLOW}ISO VirtIO non détecté automatiquement.${NC}"
        read -r -p "Nom de l'ISO VirtIO (laisser vide pour ignorer): " virtio_iso
    fi
    if [ -n "$virtio_iso" ] && [ ! -f "$ISO_STORAGE_PATH/$virtio_iso" ]; then
        error "ISO VirtIO introuvable: $ISO_STORAGE_PATH/$virtio_iso"
    fi

    ensure_autounattend_iso

    local build_vmid="$WINDOWS_BUILD_VMID"
    if [ -z "$build_vmid" ]; then
        build_vmid="$(pvesh get /cluster/nextid)"
    fi
    if qm status "$build_vmid" >/dev/null 2>&1; then
        error "VMID déjà utilisé: $build_vmid (définis WINDOWS_BUILD_VMID libre)."
    fi

    info "Création VM source Windows (VMID: $build_vmid)..."
    qm create "$build_vmid" \
      --name "$WINDOWS_BUILD_NAME" \
      --memory "$WINDOWS_BUILD_MEMORY" \
      --cores "$WINDOWS_BUILD_CORES" \
      --sockets 1 \
      --cpu host \
      --machine q35 \
      --bios ovmf \
      --ostype win11 \
      --net0 "virtio,bridge=${WINDOWS_BUILD_BRIDGE}" \
      --scsihw virtio-scsi-single >/dev/null

    qm set "$build_vmid" --scsi0 "${VM_STORAGE}:${WINDOWS_BUILD_DISK_GB}" >/dev/null
    qm set "$build_vmid" --efidisk0 "${VM_STORAGE}:1,pre-enrolled-keys=1" >/dev/null
    qm set "$build_vmid" --ide2 "${WINDOWS_ISO_STORAGE}:iso/${windows_iso},media=cdrom" >/dev/null
    qm set "$build_vmid" --ide3 "${WINDOWS_ISO_STORAGE}:iso/${AUTOUNATTEND_ISO_NAME},media=cdrom" >/dev/null
    if [ -n "$virtio_iso" ]; then
      qm set "$build_vmid" --ide0 "${WINDOWS_ISO_STORAGE}:iso/${virtio_iso},media=cdrom" >/dev/null
    fi
    qm set "$build_vmid" --boot order=ide2\;scsi0 >/dev/null
    qm set "$build_vmid" --agent 1 >/dev/null
    qm set "$build_vmid" --serial0 socket >/dev/null
    qm set "$build_vmid" --vga serial0 >/dev/null
    qm set "$build_vmid" --onboot 1 >/dev/null

    info "Démarrage de la VM d'installation..."
    qm start "$build_vmid" >/dev/null
    warning "Installation Windows en cours (attente QEMU Guest Agent, peut durer 20-60 min)..."

    if ! wait_for_qga "$build_vmid"; then
        error "QEMU Guest Agent non détecté. Vérifie la VM via console Proxmox."
    fi
    success "QEMU Guest Agent détecté"

    info "Installation cloudbase-init dans la VM..."
    guest_exec_ps "$build_vmid" "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri 'https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' -OutFile 'C:\\CloudbaseInitSetup.msi'"
    guest_exec_ps "$build_vmid" "Start-Process msiexec.exe -ArgumentList '/i C:\\CloudbaseInitSetup.msi /qn /norestart' -Wait"

    info "Sysprep + shutdown..."
    guest_exec_ps "$build_vmid" "& 'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\bin\\SetSetupComplete.cmd'; & 'C:\\Windows\\System32\\Sysprep\\Sysprep.exe' /generalize /oobe /shutdown /unattend:'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf\\Unattend.xml'"

    if ! wait_for_vm_stopped "$build_vmid"; then
        error "La VM ne s'est pas arrêtée après sysprep. Termine la préparation manuellement."
    fi
    success "VM arrêtée après sysprep"

    SOURCE_VM_ID="$build_vmid"
}

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   CRÉATION AUTOMATIQUE TEMPLATE WINDOWS       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
echo ""

existing_vmid="$(find_vmid_by_name "$TEMPLATE_NAME" || true)"
if [ -n "$existing_vmid" ] && is_template_vmid "$existing_vmid"; then
    success "Template déjà présent: $TEMPLATE_NAME (VMID: $existing_vmid)"
    exit 0
fi

if [ -z "$SOURCE_VM_ID" ]; then
    echo -e "${CYAN}Mode de création:${NC}"
    echo -e "  ${YELLOW}[1]${NC} Convertir une VM Windows déjà préparée"
    echo -e "  ${YELLOW}[2]${NC} Construire automatiquement depuis ISO"
    echo ""
    read -r -p "> " BUILD_MODE
    BUILD_MODE="${BUILD_MODE:-2}"

    if [ "$BUILD_MODE" = "2" ]; then
        auto_build_from_iso
    else
        echo -e "${CYAN}VMs disponibles:${NC}"
        qm list | sed 1d || true
        echo ""
        read -r -p "VMID source Windows déjà préparée (cloudbase-init + sysprep) : " SOURCE_VM_ID
    fi
fi

if [[ ! "$SOURCE_VM_ID" =~ ^[0-9]+$ ]]; then
    error "VMID invalide: $SOURCE_VM_ID"
fi

if ! qm status "$SOURCE_VM_ID" >/dev/null 2>&1; then
    error "VMID $SOURCE_VM_ID introuvable sur ce nœud Proxmox."
fi

if is_template_vmid "$SOURCE_VM_ID"; then
    warning "La VM $SOURCE_VM_ID est déjà un template."
else
    status="$(qm status "$SOURCE_VM_ID" | awk '{print $2}')"
    if [ "$status" = "running" ]; then
        info "Arrêt de la VM source $SOURCE_VM_ID..."
        qm shutdown "$SOURCE_VM_ID" --timeout 180 >/dev/null || true
        sleep 5
        status="$(qm status "$SOURCE_VM_ID" | awk '{print $2}')"
        if [ "$status" = "running" ]; then
            warning "Arrêt propre impossible, extinction forcée..."
            qm stop "$SOURCE_VM_ID" >/dev/null
        fi
    fi

    info "Configuration recommandée avant conversion..."
    qm set "$SOURCE_VM_ID" --agent 1 >/dev/null
    qm set "$SOURCE_VM_ID" --boot order=scsi0 >/dev/null
    qm set "$SOURCE_VM_ID" --serial0 socket >/dev/null
    qm set "$SOURCE_VM_ID" --vga serial0 >/dev/null

    info "Conversion en template..."
    qm template "$SOURCE_VM_ID" >/dev/null
fi

if [ "$(qm config "$SOURCE_VM_ID" | awk '/^name: / {print $2}')" != "$TEMPLATE_NAME" ]; then
    info "Renommage du template en ${TEMPLATE_NAME}..."
    qm set "$SOURCE_VM_ID" --name "$TEMPLATE_NAME" >/dev/null
fi

success "Template Windows prêt: $TEMPLATE_NAME (VMID: $SOURCE_VM_ID)"
echo ""
echo -e "${CYAN}Utilise cette valeur dans .env.local:${NC}"
echo -e "  ${YELLOW}WINDOWS_TEMPLATE_ID=${TEMPLATE_NAME}${NC}"
echo ""
