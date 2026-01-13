# Guide : Préparation du Template Windows Server avec Cloud-Init

Ce guide explique comment créer un template Windows Server réutilisable avec cloud-init pour Proxmox.

## Prérequis

- ISO Windows Server 2022 uploadé sur Proxmox
- Accès à l'interface web de Proxmox
- 30-45 minutes pour la préparation initiale

## Étape 1 : Créer la VM de base

1. Dans Proxmox, créer une nouvelle VM :
   - **VMID**: 100 (ou autre ID libre)
   - **Nom**: `WSERVER-TEMPLATE` (notez ce nom, vous en aurez besoin pour Terraform)
   - **OS Type**: Microsoft Windows / Server 2022
   - **BIOS**: OVMF (UEFI)
   - **Machine**: q35
   - **Disque**: 32GB minimum (VirtIO SCSI)
   - **CPU**: 2 cores (host)
   - **RAM**: 4096 MB
   - **Network**: VirtIO

2. Ajouter un EFI Disk :
   - Storage: local-lvm
   - Size: 4M

3. Monter l'ISO Windows Server et démarrer la VM

## Étape 2 : Installation Windows Server

1. Installer Windows Server 2022 Standard (Desktop Experience)
2. Configuration initiale :
   - Langue: Français
   - Fuseau horaire: Europe/Paris
   - Mot de passe Administrateur temporaire: `TempPassword123@`

3. Une fois installé, se connecter et effectuer les mises à jour Windows Update

## Étape 3 : Installer VirtIO Drivers

1. Télécharger l'ISO VirtIO drivers depuis :
   ```
   https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
   ```

2. Monter l'ISO dans Proxmox (Hardware → Add → CD/DVD)

3. Dans Windows, installer les drivers :
   - Ouvrir l'explorateur de fichiers
   - Aller sur le lecteur CD VirtIO
   - Lancer `virtio-win-gt-x64.msi`
   - Installer tous les drivers

## Étape 4 : Installer QEMU Guest Agent

1. Depuis le même ISO VirtIO, installer QEMU Guest Agent :
   ```
   D:\guest-agent\qemu-ga-x86_64.msi
   ```

2. Ou télécharger directement :
   ```powershell
   Invoke-WebRequest -Uri "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-qemu-ga/qemu-ga-x86_64.msi" -OutFile "C:\qemu-ga.msi"
   msiexec /i C:\qemu-ga.msi /qn /norestart
   ```

3. Vérifier que le service est démarré :
   ```powershell
   Get-Service QEMU-GA
   Set-Service QEMU-GA -StartupType Automatic
   ```

## Étape 5 : Installer Cloudbase-Init

1. Télécharger cloudbase-init :
   ```powershell
   Invoke-WebRequest -Uri "https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi" -OutFile "C:\CloudbaseInitSetup.msi"
   ```

2. Installer cloudbase-init :
   ```powershell
   msiexec /i C:\CloudbaseInitSetup.msi /qn /norestart
   ```

3. Configurer cloudbase-init :
   Éditer `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf` :
   ```ini
   [DEFAULT]
   username=Administrator
   groups=Administrators
   inject_user_password=true
   config_drive_raw_hhd=true
   config_drive_cdrom=true
   config_drive_vfat=true
   bsdtar_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\bsdtar.exe
   mtools_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\
   verbose=true
   debug=true
   logdir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\
   logfile=cloudbase-init.log
   default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN
   logging_serial_port_settings=
   mtu_use_dhcp_config=true
   ntp_use_dhcp_config=true
   local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\
   check_latest_version=false
   ```

4. Éditer `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf` avec le même contenu

## Étape 6 : Préparer le template

1. Nettoyer le système :
   ```powershell
   # Vider le cache
   cleanmgr /d C:

   # Arrêter les services inutiles
   Stop-Service wuauserv
   ```

2. Créer un script de sysprep personnalisé :
   `C:\prepare-template.ps1` :
   ```powershell
   # Désactiver IPv6 (optionnel)
   # Disable-NetAdapterBinding -Name "*" -ComponentID ms_tcpip6

   # Optimisations
   Set-Service -Name wuauserv -StartupType Manual

   # Sysprep avec cloudbase-init
   & 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\SetSetupComplete.cmd'

   C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:"C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"
   ```

3. Exécuter le script :
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\prepare-template.ps1
   ```

   **La VM va s'éteindre automatiquement**

## Étape 7 : Convertir en template dans Proxmox

1. Une fois la VM éteinte, dans Proxmox :
   ```bash
   qm set 100 --agent 1
   qm set 100 --boot order=scsi0
   qm set 100 --serial0 socket
   qm set 100 --vga serial0
   ```

2. Convertir en template :
   ```bash
   qm template 100
   ```

3. Le template est prêt ! Il apparaîtra dans Proxmox avec une icône différente

   **⚠️ IMPORTANT**: Dans votre configuration Terraform (`.env.local` ou `terraform.tfvars`), vous devrez utiliser le **nom** du template (`WSERVER-TEMPLATE`), pas son ID numérique (100).

## Utilisation du template

Maintenant, vous pouvez cloner ce template pour créer des VMs Windows avec cloud-init.
Les scripts Terraform du projet utiliseront ce template automatiquement.

## Vérification

Pour tester le template :
```bash
qm clone 100 999 --name test-windows
qm set 999 --cipassword Admin123@
qm set 999 --ipconfig0 ip=dhcp
qm start 999
```

La VM devrait démarrer et être accessible avec le mot de passe configuré via cloud-init.
