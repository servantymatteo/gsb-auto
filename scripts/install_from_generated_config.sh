#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <env_local_b64> <terraform_tfvars_b64> [ad_ds_b64]"
  exit 1
fi

ENV_B64="$1"
TFVARS_B64="$2"
AD_B64="${3:-}"

decode_base64_to_file() {
  local content_b64="$1"
  local output_file="$2"

  if base64 --help >/dev/null 2>&1; then
    printf '%s' "$content_b64" | base64 --decode > "$output_file" 2>/dev/null || \
      printf '%s' "$content_b64" | base64 -D > "$output_file"
  else
    printf '%s' "$content_b64" | base64 -d > "$output_file" 2>/dev/null || \
      printf '%s' "$content_b64" | base64 -D > "$output_file"
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "-> Preparation des fichiers de configuration (temp: $TMP_DIR)"

decode_base64_to_file "$ENV_B64" "$TMP_DIR/.env.local"
decode_base64_to_file "$TFVARS_B64" "$TMP_DIR/terraform.tfvars"

if [ -n "$AD_B64" ]; then
  decode_base64_to_file "$AD_B64" "$TMP_DIR/ad_ds.yml"
fi

cp "$TMP_DIR/.env.local" "$ROOT_DIR/.env.local"
cp "$TMP_DIR/terraform.tfvars" "$ROOT_DIR/terraform/terraform.tfvars"

if [ -f "$TMP_DIR/ad_ds.yml" ]; then
  mkdir -p "$ROOT_DIR/ansible/vars"
  cp "$TMP_DIR/ad_ds.yml" "$ROOT_DIR/ansible/vars/ad_ds.yml"
fi

echo "-> Fichiers config appliques:"
echo "   - $ROOT_DIR/.env.local"
echo "   - $ROOT_DIR/terraform/terraform.tfvars"
if [ -f "$TMP_DIR/ad_ds.yml" ]; then
  echo "   - $ROOT_DIR/ansible/vars/ad_ds.yml"
fi

echo "-> Lancement Terraform"
cd "$ROOT_DIR/terraform"

if [ ! -d ".terraform" ]; then
  terraform init -input=false -compact-warnings
fi

TF_IN_AUTOMATION=1 terraform apply --auto-approve -compact-warnings

echo "-> Deploiement termine"
