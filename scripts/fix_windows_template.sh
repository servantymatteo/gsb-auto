#!/bin/bash
# Script pour convertir le disque IDE en SCSI sur le template Windows

set -e

echo "🔧 Conversion du template Windows ID 100 : IDE → SCSI"
echo ""

# Convertir le template en VM
echo "1. Conversion du template en VM..."
ssh root@192.168.68.200 "qm set 100 --template 0"

# Détacher le disque IDE
echo "2. Détachement du disque IDE..."
ssh root@192.168.68.200 "qm set 100 --delete ide0"

# Attacher le disque unused sur SCSI0
echo "3. Attachement du disque sur SCSI0..."
ssh root@192.168.68.200 "qm set 100 --scsi0 local-lvm:base-100-disk-1"

# Changer le boot order
echo "4. Modification du boot order..."
ssh root@192.168.68.200 "qm set 100 --boot order=scsi0"

# Optionnel: Retirer le CD-ROM
echo "5. Retrait du CD-ROM (optionnel)..."
ssh root@192.168.68.200 "qm set 100 --delete ide2" || true

# Reconvertir en template
echo "6. Reconversion en template..."
ssh root@192.168.68.200 "qm set 100 --template 1"

echo ""
echo "✅ Template converti avec succès!"
echo ""
echo "Configuration finale:"
ssh root@192.168.68.200 "qm config 100 | grep -E 'scsi0|boot|template'"
