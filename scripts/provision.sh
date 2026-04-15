#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_CONFIG="$PROJECT_ROOT/ansible/ansible.cfg"
LOG_FILE="/tmp/gsb-provision-$$.log"

SSH_KEY="$PROJECT_ROOT/ssh/id_ed25519_terraform"
if [[ ! -f "$SSH_KEY" ]]; then
  [[ -f "$HOME/.ssh/id_ed25519" ]] && SSH_KEY="$HOME/.ssh/id_ed25519" \
    || { [[ -f "$HOME/.ssh/id_rsa" ]] && SSH_KEY="$HOME/.ssh/id_rsa"; }
fi

CONTAINER_NAME="$1"
CONTAINER_IP="$2"
PLAYBOOK="$3"

# provision.sh est lancé en PARALLÈLE par Terraform pour chaque container.
# On utilise /dev/tty pour afficher sur le terminal, et des echo simples
# (atomiques) sans spinner pour éviter l'entrelacement entre processus.
TTY=/dev/tty
[[ ! -w "$TTY" ]] && TTY=/dev/stderr

log_step() { echo -e "  ${CYAN}⠿${NC} $*" >"$TTY"; }
log_ok()   { echo -e "  ${GREEN}✓${NC} $*" >"$TTY"; }
log_fail() {
  echo -e "  ${RED}✗${NC} $*" >"$TTY"
  if [[ -s "$LOG_FILE" ]]; then
    echo -e "  ${DIM}--- erreur ---${NC}" >"$TTY"
    { grep -E "FAILED|fatal|ERROR" "$LOG_FILE" | tail -6 \
        || tail -6 "$LOG_FILE"; } | sed 's/^/    /' >"$TTY"
    echo -e "  ${DIM}log: ${LOG_FILE}${NC}" >"$TTY"
  fi
}

if [[ -z "$CONTAINER_IP" ]]; then
  log_fail "[${CONTAINER_NAME}] IP non fournie"
  exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
  log_fail "[${CONTAINER_NAME}] Clé SSH introuvable"
  exit 1
fi

# ── Attente SSH ───────────────────────────────────────────────────────────
log_step "[${CONTAINER_NAME}] Attente SSH (${CONTAINER_IP})..."
connected=0
for i in $(seq 1 30); do
  if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=3 root@"$CONTAINER_IP" 'exit' >>"$LOG_FILE" 2>&1; then
    connected=1
    break
  fi
  sleep 5
done

if [[ "$connected" == "0" ]]; then
  log_fail "[${CONTAINER_NAME}] SSH timeout"
  exit 1
fi
log_ok "[${CONTAINER_NAME}] SSH OK"

# ── Ansible ───────────────────────────────────────────────────────────────
SERVICE=$(basename "$PLAYBOOK" .yml | sed 's/install_//')
log_step "[${CONTAINER_NAME}] Installation ${SERVICE}..."

# Charger un fichier de vars spécifique au service si il existe
EXTRA_VARS=""
VARS_FILE="$PROJECT_ROOT/ansible/vars/${SERVICE}_config.yml"
if [[ -f "$VARS_FILE" ]]; then
  EXTRA_VARS="@${VARS_FILE}"
fi

ANSIBLE_FORCE_COLOR=0 ANSIBLE_CONFIG="$ANSIBLE_CONFIG" ANSIBLE_HOST_KEY_CHECKING=False \
  ansible-playbook \
  --private-key="$SSH_KEY" \
  -i "${CONTAINER_IP}," \
  -u root \
  ${EXTRA_VARS:+--extra-vars "$EXTRA_VARS"} \
  "$PLAYBOOK" >>"$LOG_FILE" 2>&1 \
  && log_ok "[${CONTAINER_NAME}] ${SERVICE} installé" \
  || { log_fail "[${CONTAINER_NAME}] ${SERVICE} échoué"; exit 1; }
