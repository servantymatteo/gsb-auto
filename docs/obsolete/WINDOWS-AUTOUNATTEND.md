# 🪟 Guide Windows Server & Active Directory

Guide complet pour déployer un contrôleur de domaine Active Directory sur Windows Server 2022 avec Proxmox + Terraform + Ansible.

## 📋 Table des matières

- [Démarrage rapide (Installation manuelle)](#-démarrage-rapide-installation-manuelle)
- [Installation automatique (Avancé)](#-installation-automatique-avancé)
- [Configuration Active Directory](#-configuration-active-directory)
- [Dépannage](#-dépannage)

---

## ⚡ Démarrage rapide (Installation manuelle)

**Recommandé pour débutants** - Plus simple et fiable.

### Étape 1 : Lancer le déploiement

```bash
./setup.sh
```

Sélectionner : `[5] Active Directory (contrôleur de domaine Windows)`

Configuration recommandée :
- Nom : `dc`
- CPU : `4 cores`
- RAM : `4096 MB` (4 Go minimum)
- Disque : `60G`

### Étape 2 : Installer Windows via console Proxmox

1. **Ouvrir la console** : Proxmox → Cliquer sur la VM → Console (noVNC)

2. **Installation Windows** (~15 minutes) :
   - Appuyer sur une touche pour démarrer depuis le DVD
   - Langue : Français
   - Clavier : Français (France)
   - **Installer maintenant**
   - Version : **Windows Server 2022 Standard (Expérience de bureau)**
   - Accepter les termes
   - Type d'installation : **Personnalisée**
   - Disque : Sélectionner le disque 60 Go → **Suivant**
   - Attendre l'installation (~10 min)

3. **Configuration initiale** :
   - Mot de passe Administrateur : `Admin123@`
   - Confirmer : `Admin123@`
   - Appuyer sur Ctrl+Alt+Suppr (icône en haut de la console)
   - Se connecter avec le mot de passe

### Étape 3 : Activer WinRM

Dans la VM Windows, **clic droit sur Menu Démarrer → PowerShell (admin)** :

```powershell
# Activer WinRM pour Ansible
Enable-PSRemoting -Force

# Configurer l'authentification
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true

# Ouvrir le pare-feu
New-NetFirewallRule -Name "WinRM-HTTP" -DisplayName "WinRM HTTP" -Enabled True -Direction Inbound -Protocol TCP -LocalPort 5985

# Vérifier que WinRM fonctionne
Test-WSMan -ComputerName localhost
```

### Étape 4 : Récupérer l'IP de la VM

Dans **PowerShell Windows** :
```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike "127.*"} | Select IPAddress
```

Ou dans **Proxmox** : VM → Summary → IP Address

### Étape 5 : Lancer Ansible

Sur votre **machine locale (macOS/Linux)** :

```bash
pwsh scripts/provision_windows.ps1 \
  -VMName gsb-dc \
  -VMIP <IP_DE_LA_VM> \
  -Playbook ansible/playbooks/install_ad_ds.yml
```

**Exemple** :
```bash
pwsh scripts/provision_windows.ps1 \
  -VMName gsb-dc \
  -VMIP 192.168.68.150 \
  -Playbook ansible/playbooks/install_ad_ds.yml
```

Ansible va (~20 minutes) :
1. Installer AD DS + DNS + RSAT
2. Promouvoir le serveur en contrôleur de domaine
3. Redémarrer
4. Créer les OUs, groupes et utilisateurs

---

## 🔧 Installation automatique (Avancé)

Pour une installation 100% automatisée de Windows (sans interaction), vous devez créer un ISO contenant `autounattend.xml`.

### Prérequis

```bash
# macOS
brew install cdrtools

# Linux
sudo apt install genisoimage
```

### Étape 1 : Créer l'ISO autounattend

```bash
cd scripts
./create_autounattend_iso.sh
```

Cela crée `terraform/autounattend.iso`.

### Étape 2 : Uploader sur Proxmox

```bash
scp ../terraform/autounattend.iso root@192.168.68.200:/var/lib/vz/template/iso/
```

Ou via l'interface Proxmox :
1. Datacenter → Storage → local (proxmox)
2. ISO Images → Upload
3. Sélectionner `autounattend.iso`

### Étape 3 : Ajouter l'ISO à la VM

**Via CLI Proxmox** :
```bash
ssh root@192.168.68.200
qm set <VMID> -ide3 local:iso/autounattend.iso,media=cdrom
qm reset <VMID>
```

**Via interface Proxmox** :
1. Sélectionner la VM
2. Hardware → Add → CD/DVD Drive
3. Storage : local
4. ISO image : autounattend.iso
5. OK
6. Redémarrer la VM

### Résultat

Windows s'installe automatiquement (~15 min) :
- Partitionnement automatique
- Installation de l'OS
- Configuration initiale
- Activation de WinRM
- Prêt pour Ansible !

---

## 📊 Configuration Active Directory

### Informations de connexion

#### Serveur Windows

```
Accès RDP : <IP_VM>:3389
Utilisateur : Administrator
Mot de passe : Admin123@
```

#### Domaine Active Directory

```
Nom de domaine : gsb.local
NetBIOS : GSB
Safe Mode Password : SafeMode123@
```

#### Compte administrateur domaine

```
Utilisateur : admin.gsb@gsb.local
Mot de passe : Admin123@
Groupes : Domain Admins, Admins_GSB
```

#### Comptes utilisateurs de test

```
user1.gsb@gsb.local / User123@
user2.gsb@gsb.local / User123@
user3.gsb@gsb.local / User123@
```

### Structure Active Directory

```
gsb.local (Domaine racine)
├── Builtin (par défaut)
├── Computers (par défaut)
├── Domain Controllers (par défaut)
├── Users (par défaut)
├── Utilisateurs_GSB (OU personnalisée)
│   ├── admin.gsb (utilisateur)
│   ├── user1.gsb (utilisateur)
│   ├── user2.gsb (utilisateur)
│   ├── user3.gsb (utilisateur)
│   └── Admins_GSB (groupe de sécurité)
├── Ordinateurs_GSB (OU personnalisée)
└── Serveurs_GSB (OU personnalisée)
```

### Vérifier Active Directory

Dans **PowerShell Windows** :

```powershell
# Vérifier le domaine
Get-ADDomain

# Lister les utilisateurs
Get-ADUser -Filter * | Select Name, SamAccountName

# Lister les OUs
Get-ADOrganizationalUnit -Filter * | Select Name, DistinguishedName

# Lister les groupes
Get-ADGroup -Filter * | Select Name, GroupScope
```

---

## 🛠️ Dépannage

### La VM ne démarre pas

**Vérifier la configuration UEFI** :

```bash
ssh root@proxmox
qm config <VMID>
```

Doit contenir :
```
boot: order=ide2;scsi0
bios: ovmf
efidisk0: local-lvm:vm-<VMID>-disk-0,efitype=4m,pre-enrolled-keys=1,size=1M
ide2: drive:iso/SERVER_EVAL_x64FRE_fr-fr.iso,media=cdrom
```

**Si incorrect** :
```bash
qm set <VMID> -boot order=ide2;scsi0
qm reboot <VMID>
```

### Windows ne détecte pas autounattend.xml

**Causes** :
- L'ISO autounattend n'est pas monté
- Le fichier n'est pas à la racine de l'ISO
- Le format du fichier est incorrect (doit être UTF-8)

**Solution** :
```bash
# Recréer l'ISO
cd scripts
./create_autounattend_iso.sh

# Re-uploader
scp ../terraform/autounattend.iso root@192.168.68.200:/var/lib/vz/template/iso/

# Vérifier qu'il est monté (via Proxmox)
# VM → Hardware → ide3 doit afficher local:iso/autounattend.iso
```

### WinRM ne répond pas

**Test de connectivité** :

```bash
# Depuis votre machine
ping <IP_VM>

# Test WinRM
nc -zv <IP_VM> 5985
```

**Dans la VM Windows (via console)** :

```powershell
# Vérifier le service
Get-Service WinRM

# Redémarrer si nécessaire
Restart-Service WinRM

# Vérifier la config
Test-WSMan -ComputerName localhost

# Vérifier le pare-feu
Get-NetFirewallRule -Name "WinRM*" | Select Name, Enabled

# Vérifier les listeners
winrm enumerate winrm/config/listener
```

### Ansible échoue

**Test manuel de connexion** :

```bash
# Tester win_ping
ansible windows -i <IP>, \
  -e ansible_user=Administrator \
  -e ansible_password=Admin123@ \
  -e ansible_connection=winrm \
  -e ansible_winrm_transport=basic \
  -e ansible_port=5985 \
  -m win_ping
```

**Vérifier pywinrm** :

```bash
python3 -c "import winrm; print('pywinrm OK')"
```

**Relancer Ansible manuellement** :

```bash
pwsh scripts/provision_windows.ps1 \
  -VMName gsb-dc \
  -VMIP <IP> \
  -Playbook ansible/playbooks/install_ad_ds.yml
```

### Installation Windows bloquée

**Si Windows demande une interaction** :

1. Installer Windows manuellement (Étape 2 du guide rapide)
2. Activer WinRM (Étape 3)
3. Lancer Ansible (Étape 5)

### La VM est lente

**Optimisations** :

```bash
# Augmenter les ressources
qm set <VMID> -cores 4 -memory 8192

# Utiliser CPU host
qm set <VMID> -cpu host

# Redémarrer
qm reboot <VMID>
```

---

## ⚠️ Sécurité

**Cette configuration est pour APPRENTISSAGE uniquement !**

### Vulnérabilités actuelles

- ❌ Mots de passe en clair dans la configuration
- ❌ WinRM en Basic Authentication (non chiffré)
- ❌ Certificats SSL auto-signés ignorés
- ❌ AllowUnencrypted activé
- ❌ Pas de GPO de sécurité

### Pour la production

- ✅ Changer TOUS les mots de passe
- ✅ Utiliser HTTPS pour WinRM (port 5986)
- ✅ Configurer des certificats SSL valides
- ✅ Utiliser Kerberos ou NTLM
- ✅ Désactiver Basic Auth
- ✅ Implémenter des GPO de sécurité
- ✅ Activer le chiffrement SMB
- ✅ Configurer Windows Defender
- ✅ Mettre en place des sauvegardes AD

---

## 📊 Timeline de déploiement

| Étape | Durée | Description |
|-------|-------|-------------|
| Terraform crée la VM | 30s | Création de la VM QEMU avec UEFI |
| Boot Windows | 30s | Démarrage depuis l'ISO |
| Installation Windows | 15 min | Installation de l'OS (manuel ou auto) |
| Configuration initiale | 2 min | Premier démarrage + activation WinRM |
| Ansible : Installation AD DS | 5 min | Installation des rôles |
| Ansible : Promotion DC | 10 min | Configuration du domaine + redémarrage |
| Ansible : Configuration | 5 min | OUs, groupes, utilisateurs |
| **TOTAL** | **~40 min** | |

---

## 🎯 Commandes rapides

```bash
# Créer l'ISO autounattend
cd scripts && ./create_autounattend_iso.sh

# Uploader sur Proxmox
scp ../terraform/autounattend.iso root@proxmox:/var/lib/vz/template/iso/

# Déployer
./setup.sh  # Sélectionner [5] Active Directory

# Vérifier l'IP
qm guest cmd <VMID> network-get-interfaces

# Lancer Ansible manuellement
pwsh scripts/provision_windows.ps1 -VMName gsb-dc -VMIP <IP> -Playbook ansible/playbooks/install_ad_ds.yml

# Accéder via RDP
open rdp://administrator:Admin123@@<IP>

# Supprimer
./cleanup.sh
```

---

## 📚 Fichiers impliqués

| Fichier | Description |
|---------|-------------|
| [terraform/main.tf](../terraform/main.tf) | Configuration UEFI, VMs QEMU |
| [terraform/autounattend.xml](../terraform/autounattend.xml) | Installation automatique Windows |
| [ansible/playbooks/install_ad_ds.yml](../ansible/playbooks/install_ad_ds.yml) | Installation Active Directory |
| [scripts/provision_windows.ps1](../scripts/provision_windows.ps1) | Provisioning Windows + WinRM |
| [scripts/create_autounattend_iso.sh](../scripts/create_autounattend_iso.sh) | Création ISO autounattend |

---

**Besoin d'aide ?** Consultez [TROUBLESHOOTING.md](TROUBLESHOOTING.md) pour plus de solutions.
