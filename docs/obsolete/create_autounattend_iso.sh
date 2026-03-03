#!/bin/bash

# Script pour créer un ISO contenant autounattend.xml
# Cet ISO sera monté comme second CD-ROM pendant l'installation Windows

set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  CRÉATION ISO AUTOUNATTEND.XML        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# Vérifier que genisoimage ou mkisofs est installé
if ! command -v genisoimage &> /dev/null && ! command -v mkisofs &> /dev/null; then
    echo -e "${RED}✗ Erreur: genisoimage ou mkisofs n'est pas installé${NC}"
    echo ""
    echo -e "${YELLOW}Installation requise:${NC}"
    echo -e "  macOS:   ${GREEN}brew install cdrtools${NC}"
    echo -e "  Debian:  ${GREEN}sudo apt-get install genisoimage${NC}"
    echo -e "  RHEL:    ${GREEN}sudo yum install genisoimage${NC}"
    echo ""
    exit 1
fi

# Déterminer quelle commande utiliser
if command -v genisoimage &> /dev/null; then
    ISO_CMD="genisoimage"
else
    ISO_CMD="mkisofs"
fi

# Répertoires
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"
AUTOUNATTEND_XML="$TERRAFORM_DIR/autounattend.xml"
OUTPUT_ISO="$TERRAFORM_DIR/autounattend.iso"
TEMP_DIR=$(mktemp -d)

# Vérifier que autounattend.xml existe
if [ ! -f "$AUTOUNATTEND_XML" ]; then
    echo -e "${RED}✗ Fichier autounattend.xml non trouvé: $AUTOUNATTEND_XML${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo -e "${YELLOW}→ Préparation des fichiers...${NC}"
cp "$AUTOUNATTEND_XML" "$TEMP_DIR/"
echo -e "${GREEN}✓ Fichiers copiés${NC}"

echo -e "${YELLOW}→ Création de l'ISO...${NC}"
$ISO_CMD -o "$OUTPUT_ISO" \
    -J -R -V "AUTOUNATTEND" \
    -input-charset utf-8 \
    "$TEMP_DIR" 2>&1 | grep -v "Warning: creating filesystem" || true

# Nettoyage
rm -rf "$TEMP_DIR"

if [ -f "$OUTPUT_ISO" ]; then
    ISO_SIZE=$(du -h "$OUTPUT_ISO" | cut -f1)
    echo -e "${GREEN}✓ ISO créé avec succès${NC}"
    echo ""
    echo -e "${BLUE}📦 Fichier créé:${NC}"
    echo -e "   Chemin: ${GREEN}$OUTPUT_ISO${NC}"
    echo -e "   Taille: ${GREEN}$ISO_SIZE${NC}"
    echo ""
    echo -e "${YELLOW}⚠  Étape suivante:${NC}"
    echo -e "   Uploadez cet ISO sur Proxmox dans le stockage 'local' :"
    echo -e "   ${GREEN}scp $OUTPUT_ISO root@proxmox:/var/lib/vz/template/iso/${NC}"
    echo ""
else
    echo -e "${RED}✗ Erreur lors de la création de l'ISO${NC}"
    exit 1
fi
