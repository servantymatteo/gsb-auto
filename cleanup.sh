#!/bin/bash

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║  NETTOYAGE DES CONTAINERS & VMs PROXMOX      ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""

# Vérifier si Terraform est initialisé
if [ ! -d "terraform/.terraform" ]; then
    echo -e "${RED}✗ Terraform n'est pas initialisé${NC}"
    echo ""
    echo "Lancez d'abord : cd terraform && terraform init"
    exit 1
fi

# Vérifier si le fichier tfstate existe
if [ ! -f "terraform/terraform.tfstate" ]; then
    echo -e "${YELLOW}⚠️  Aucun état Terraform trouvé${NC}"
    echo ""
    echo "Aucun container n'a été créé par ce système."
    exit 0
fi

# Lister les ressources gérées par Terraform
echo -e "${BLUE}Ressources gérées par Terraform :${NC}"
echo ""

cd terraform

# Récupérer les containers LXC
LXC_RESOURCES=$(terraform state list 2>/dev/null | grep "proxmox_lxc.container")
# Récupérer les VMs Windows (QEMU)
QEMU_RESOURCES=$(terraform state list 2>/dev/null | grep "proxmox_vm_qemu.windows_vm")

if [ -z "$LXC_RESOURCES" ] && [ -z "$QEMU_RESOURCES" ]; then
    echo -e "${YELLOW}⚠️  Aucune ressource trouvée${NC}"
    echo ""
    cd ..
    exit 0
fi

# Afficher les containers LXC
LXC_COUNT=0
if [ -n "$LXC_RESOURCES" ]; then
    echo -e "${GREEN}Containers LXC (Linux) :${NC}"
    while IFS= read -r resource; do
        # Extraire le nom du container depuis l'état
        CONTAINER_NAME=$(terraform state show "$resource" 2>/dev/null | grep "hostname" | awk '{print $3}' | tr -d '"')
        VMID=$(terraform state show "$resource" 2>/dev/null | grep "^    id" | awk '{print $3}' | tr -d '"' | cut -d'/' -f3)

        if [ -n "$CONTAINER_NAME" ]; then
            echo "  • $CONTAINER_NAME (VMID: $VMID)"
            LXC_COUNT=$((LXC_COUNT + 1))
        fi
    done <<< "$LXC_RESOURCES"
    echo ""
fi

# Afficher les VMs QEMU (Windows)
QEMU_COUNT=0
if [ -n "$QEMU_RESOURCES" ]; then
    echo -e "${GREEN}VMs QEMU (Windows) :${NC}"
    while IFS= read -r resource; do
        # Extraire le nom de la VM depuis les triggers
        VM_NAME=$(terraform state show "$resource" 2>/dev/null | grep "vm_name" | head -1 | awk '{print $3}' | tr -d '"')

        if [ -n "$VM_NAME" ]; then
            echo "  • $VM_NAME (Windows Server)"
            QEMU_COUNT=$((QEMU_COUNT + 1))
        fi
    done <<< "$QEMU_RESOURCES"
    echo ""
fi

TOTAL_COUNT=$((LXC_COUNT + QEMU_COUNT))
echo -e "${YELLOW}Total : $LXC_COUNT container(s) LXC + $QEMU_COUNT VM(s) QEMU = $TOTAL_COUNT ressource(s)${NC}"
echo ""

# Demander confirmation
echo -e "${RED}⚠️  ATTENTION : Cette action va supprimer toutes ces ressources (containers + VMs) !${NC}"
echo ""
read -p "Voulez-vous continuer ? (oui/non) : " CONFIRM

if [[ "$CONFIRM" != "oui" ]]; then
    echo ""
    echo "Annulé."
    cd ..
    exit 0
fi

echo ""
echo -e "${BLUE}Suppression des ressources (containers + VMs)...${NC}"
echo ""

# Supprimer via Terraform
terraform destroy -auto-approve

if [ $? -eq 0 ]; then
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║         NETTOYAGE TERMINÉ ! ✓                ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    echo -e "${GREEN}Toutes les ressources (containers + VMs) ont été supprimées.${NC}"
    echo ""
else
    echo ""
    echo -e "${RED}✗ Erreur lors de la suppression${NC}"
    echo ""
    echo "Vous pouvez essayer manuellement :"
    echo "  cd terraform && terraform destroy"
    echo ""
    cd ..
    exit 1
fi

cd ..
