#!/bin/bash
# Fonctions communes pour tous les scripts du projet
# Source ce fichier avec: source "$(dirname "$0")/common.sh"

# Couleurs
export BLUE='\033[0;34m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export CYAN='\033[0;36m'
export MAGENTA='\033[0;35m'
export BOLD='\033[1m'
export NC='\033[0m'

# Afficher un header avec bordure
# Usage: print_header "TITRE" "couleur"
print_header() {
    local title="$1"
    local color="${2:-$BLUE}"
    echo ""
    echo -e "${color}╔════════════════════════════════════════╗${NC}"
    printf "${color}║ %-38s ║${NC}\n" "$title"
    echo -e "${color}╚════════════════════════════════════════╝${NC}"
    echo ""
}

# Afficher un message de succès
# Usage: success "Message"
success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Afficher un message d'erreur et quitter
# Usage: error "Message" [exit_code]
error() {
    echo -e "${RED}✗ $1${NC}" >&2
    exit "${2:-1}"
}

# Afficher un message d'info
# Usage: info "Message"
info() {
    echo -e "${CYAN}→ $1${NC}"
}

# Afficher un warning
# Usage: warning "Message"
warning() {
    echo -e "${YELLOW}⚠  $1${NC}"
}

# Retry une commande avec timeout
# Usage: retry_command <max_attempts> <sleep_seconds> <command...>
retry_command() {
    local max_attempts=$1
    local sleep_time=$2
    shift 2
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@" 2>/dev/null; then
            return 0
        fi
        [ $attempt -eq $max_attempts ] && return 1
        sleep "$sleep_time"
        ((attempt++))
    done
    return 1
}

# Vérifier qu'une commande existe
# Usage: require_command "command_name" "install_hint"
require_command() {
    if ! command -v "$1" &> /dev/null; then
        error "$1 n'est pas installé. $2"
    fi
}

# Chemins du projet (calculés une seule fois)
if [ -z "$PROJECT_ROOT" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    export TERRAFORM_DIR="$PROJECT_ROOT/terraform"
    export ANSIBLE_DIR="$PROJECT_ROOT/ansible"
    export SSH_DIR="$PROJECT_ROOT/ssh"
    export SSH_KEY="$SSH_DIR/id_ed25519_terraform"
    export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
fi
