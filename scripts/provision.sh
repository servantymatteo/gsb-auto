#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

_SPINNER_PID=""
_SPINNER_MSG=""

# Toujours écrire sur /dev/tty : provision.sh est appelé depuis terraform (local-exec)
# dont le stdout est redirigé. On force l'affichage sur le terminal réel.
TTY=/dev/tty
[[ ! -w "$TTY" ]] && TTY=/dev/stderr

_spinner_loop() {
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while true; do
    printf "\r  \033[0;36m${frames[$i]}\033[0m %s" "$_SPINNER_MSG" >"$TTY"
    i=$(( (i + 1) % 10 ))
    sleep 0.08
  done
}

start_spinner() {
  _SPINNER_MSG="$1"
  _spinner_loop &
  _SPINNER_PID=$!
  disown "$_SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
  local status="${1:-0}"
  [[ -n "$_SPINNER_PID" ]] && { kill "$_SPINNER_PID" 2>/dev/null || true; _SPINNER_PID=""; }
  printf "\r\033[K" >"$TTY"
  if [[ "$status" == "0" ]]; then
    echo -e "  ${GREEN}✓${NC} ${_SPINNER_MSG}" >"$TTY"
  else
    echo -e "  ${RED}✗${NC} ${_SPINNER_MSG}" >"$TTY"
    if [[ -s "$LOG_FILE" ]]; then
      echo -e "  ${DIM}--- erreur ---${NC}" >"$TTY"
      { grep -E "FAILED|fatal|ERROR|error" "$LOG_FILE" | tail -8 \
          || tail -8 "$LOG_FILE"; } | sed 's/^/    /' >"$TTY"
      echo -e "  ${DIM}log complet: ${LOG_FILE}${NC}" >"$TTY"
    fi
  fi
}

if [[ -z "$CONTAINER_IP" ]]; then
  echo -e "  ${RED}✗${NC} [${CONTAINER_NAME}] IP non fournie"
  exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
  echo -e "  ${RED}✗${NC} [${CONTAINER_NAME}] Clé SSH introuvable"
  exit 1
fi

# ── Attente SSH ───────────────────────────────────────────────────────────
start_spinner "[${CONTAINER_NAME}] Attente SSH (${CONTAINER_IP})..."
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
  stop_spinner 1
  exit 1
fi
stop_spinner 0

# ── Ansible ───────────────────────────────────────────────────────────────
start_spinner "[${CONTAINER_NAME}] Installation $(basename "$PLAYBOOK" .yml | sed 's/install_//')..."

ANSIBLE_FORCE_COLOR=0 ANSIBLE_CONFIG="$ANSIBLE_CONFIG" ANSIBLE_HOST_KEY_CHECKING=False \
  ansible-playbook \
  --private-key="$SSH_KEY" \
  -i "${CONTAINER_IP}," \
  -u root \
  "$PLAYBOOK" >>"$LOG_FILE" 2>&1

ansible_status=$?
stop_spinner "$ansible_status"
exit "$ansible_status"
