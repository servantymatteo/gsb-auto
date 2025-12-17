#!/bin/bash

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo ""
echo "╔════════════════════════════════════════╗"
echo "║    NETTOYAGE DES CONTAINERS PROXMOX    ║"
echo "╚════════════════════════════════════════╝"
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

# Lister les containers gérés par Terraform
echo -e "${BLUE}Containers gérés par Terraform :${NC}"
echo ""

cd terraform

# Récupérer la liste des ressources
RESOURCES=$(terraform state list 2>/dev/null | grep "proxmox_lxc.container")

if [ -z "$RESOURCES" ]; then
    echo -e "${YELLOW}⚠️  Aucun container trouvé${NC}"
    echo ""
    cd ..
    exit 0
fi

# Afficher les containers
COUNT=0
while IFS= read -r resource; do
    # Extraire le nom du container depuis l'état
    CONTAINER_NAME=$(terraform state show "$resource" 2>/dev/null | grep "hostname" | awk '{print $3}' | tr -d '"')
    VMID=$(terraform state show "$resource" 2>/dev/null | grep "^    id" | awk '{print $3}' | tr -d '"' | cut -d'/' -f3)

    if [ -n "$CONTAINER_NAME" ]; then
        echo "  • $CONTAINER_NAME (VMID: $VMID)"
        COUNT=$((COUNT + 1))
    fi
done <<< "$RESOURCES"

echo ""
echo -e "${YELLOW}Total : $COUNT container(s)${NC}"
echo ""

# Demander confirmation
echo -e "${RED}⚠️  ATTENTION : Cette action va supprimer tous ces containers !${NC}"
echo ""
read -p "Voulez-vous continuer ? (oui/non) : " CONFIRM

if [[ "$CONFIRM" != "oui" ]]; then
    echo ""
    echo "Annulé."
    cd ..
    exit 0
fi

echo ""
echo -e "${BLUE}Suppression des containers...${NC}"
echo ""

# Supprimer via Terraform
terraform destroy -auto-approve

if [ $? -eq 0 ]; then
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║      NETTOYAGE TERMINÉ ! ✓             ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    echo -e "${GREEN}Tous les containers ont été supprimés.${NC}"
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
