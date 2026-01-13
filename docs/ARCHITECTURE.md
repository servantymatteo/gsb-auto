# 🏗️ Architecture et Fonctionnement Complet

Guide technique détaillé expliquant **comment tout fonctionne** dans le projet auto_gsb.

---

## 📋 Table des matières

1. [Vue d'ensemble](#vue-densemble)
2. [Flux de déploiement](#flux-de-déploiement)
3. [Architecture des composants](#architecture-des-composants)
4. [Détails techniques](#détails-techniques)
5. [Cas d'usage par service](#cas-dusage-par-service)

---

## 🎯 Vue d'ensemble

### Objectif du projet
Automatiser le déploiement d'infrastructures Proxmox (containers LXC Linux + VMs QEMU Windows) avec configuration automatique via Ansible.

### Stack technique
```
┌─────────────────────────────────────────┐
│  setup.sh (Interface utilisateur)      │
└────────────┬────────────────────────────┘
             │
             ├─→ Terraform (Infrastructure)
             │   └─→ Proxmox API
             │       ├─→ LXC Containers (Linux)
             │       └─→ QEMU VMs (Windows)
             │
             └─→ Ansible (Configuration)
                 └─→ Playbooks
                     ├─→ SSH (Linux)
                     └─→ WinRM (Windows)
```

### Philosophie
- **Infrastructure as Code** : Tout est versionné
- **Idempotence** : Ré-exécutable sans effet de bord
- **Automatisation complète** : De la VM à l'application configurée

---

## 🔄 Flux de déploiement

### 1. Lancement par l'utilisateur

```bash
./setup.sh
```

**Ce qui se passe :**
1. Chargement de `.env.local` (credentials Proxmox)
2. Affichage du menu des services disponibles
3. Configuration de la VM (nom, CPU, RAM, disque)
4. Génération de `terraform/terraform.tfvars`

### 2. Phase Terraform (Infrastructure)

```bash
cd terraform && terraform apply
```

#### Pour les containers LXC (Linux)

**Fichier** : [terraform/main.tf](../terraform/main.tf) (lignes 21-68)

```hcl
resource "proxmox_lxc" "container" {
  for_each = local.lxc_configs  # Filtre: playbooks != install_ad_ds.yml

  # Création du container
  target_node  = var.target_node
  hostname     = "${var.vm_name}-${each.key}"
  ostemplate   = "local:vztmpl/${var.template_name}"

  # Ressources
  cores   = each.value.cores
  memory  = each.value.memory

  # Stockage
  rootfs {
    storage = var.vm_storage
    size    = each.value.disk
  }

  # Réseau (DHCP)
  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = "dhcp"
  }

  # Cloud-init (utilisateur + clé SSH)
  ssh_public_keys = var.ssh_keys

  # ⚡ PROVISIONER: Appel au script provision.sh
  provisioner "local-exec" {
    command = "../scripts/provision.sh \"${var.vm_name}-${each.key}\" ..."
  }
}
```

**Ce que fait Terraform :**
1. ✅ Appelle l'API Proxmox pour créer le container
2. ✅ Configure le réseau en DHCP
3. ✅ Injecte la clé SSH publique
4. ✅ Démarre le container
5. ✅ **Déclenche le provisioner** → `scripts/provision.sh`

#### Pour les VMs Windows (QEMU)

**Fichier** : [terraform/main.tf](../terraform/main.tf) (lignes 74-209)

```hcl
resource "proxmox_vm_qemu" "windows_vm" {
  for_each = local.qemu_vms  # Filtre: playbook == install_ad_ds.yml

  # Configuration de base
  name        = "${var.vm_name}-${each.key}"
  target_node = var.target_node

  # Clone depuis template Windows avec cloud-init
  clone      = var.windows_template_id  # Nom du template (en string)
  full_clone = true

  # Configuration matérielle
  cores   = each.value.cores
  memory  = each.value.memory
  cpu     = "host"
  bios    = "ovmf"      # ← UEFI
  machine = "q35"       # ← Architecture moderne

  # Disque (cloné depuis le template)
  disk {
    storage  = var.vm_storage
    type     = "scsi"
    size     = each.value.disk_size
    discard  = "on"
    iothread = 1
  }

  # Configuration Cloud-Init
  ciuser     = "Administrator"
  cipassword = var.windows_admin_password
  ipconfig0  = "ip=dhcp"
  cicustom   = "user=local:snippets/windows-firstboot-adds.yml"

  provisioner "local-exec" {
    command = <<-EOT
      # [1] Attendre que cloud-init configure la VM (60s)

      # [2] Récupérer l'IP via QEMU Guest Agent
      for i in {1..60}; do
        VM_IP=$(curl .../qemu/$VMID/agent/network-get-interfaces)
        [ -n "$VM_IP" ] && break
        sleep 30
      done

      # [5] Lancer le provisioning PowerShell
      pwsh ../scripts/provision_windows.ps1 \
        -VMName "${vm_name}" \
        -VMIP "$VM_IP" \
        -Playbook "../ansible/playbooks/${playbook}"
    EOT
  }
}
```

**Pourquoi `null_resource` et pas `proxmox_vm_qemu` ?**

Le provider Terraform `telmate/proxmox` v2.9.14 **ne supporte pas** `efidisk0`, obligatoire pour Windows Server moderne. Solution : appels directs à l'API Proxmox via `curl`.

**Configuration UEFI critique** :
- `bios=ovmf` : BIOS UEFI (requis pour Windows Server 2022)
- `efidisk0` : Disque pour les variables UEFI
- `machine=q35` : Architecture moderne (vs i440fx)
- `boot=order=ide2;scsi0` : Boot CD-ROM en premier

### 3. Phase Provisioning (Configuration)

#### Linux (via scripts/provision.sh)

**Fichier** : [scripts/provision.sh](../scripts/provision.sh)

```bash
#!/bin/bash
source "$(dirname "$0")/common.sh"

# [1] Attendre le démarrage (25s)
sleep 25

# [2] Récupérer VMID et IP via API Proxmox
VMID=$(curl .../lxc | grep "name\":\"$CONTAINER_NAME" | extract vmid)
CONTAINER_IP=$(curl .../lxc/$VMID/interfaces | grep IP)

# [3] Test SSH (retry 20x avec 3s de pause)
retry_command 20 3 ssh -i "$SSH_KEY" root@$CONTAINER_IP 'exit'

# [4] Lancer Ansible
ANSIBLE_CONFIG="$PROJECT_ROOT/ansible/ansible.cfg" ansible-playbook \
  --private-key="$SSH_KEY" \
  -i "$CONTAINER_IP," \
  -u root \
  "$PLAYBOOK"  # Ex: ../ansible/playbooks/install_apache.yml
```

**Pourquoi 25 secondes ?** Temps pour que le container démarre + obtienne une IP DHCP + démarre SSH.

#### Windows (via scripts/provision_windows.ps1)

**Fichier** : [scripts/provision_windows.ps1](../scripts/provision_windows.ps1)

```powershell
# [1] Test WinRM (port 5985, retry 60x avec 5s)
for ($i = 1; $i -le 60; $i++) {
    $testConnection = Test-WSMan -ComputerName $VMIP
    if ($testConnection) { break }
    Start-Sleep -Seconds 5
}

# [2] Lancer Ansible avec connexion WinRM
$env:ANSIBLE_CONFIG = "$PROJECT_ROOT/ansible/ansible.cfg"
ansible-playbook `
  -i "$VMIP," `
  -e "ansible_user=Administrator" `
  -e "ansible_password=Admin123@" `
  -e "ansible_connection=winrm" `
  -e "ansible_winrm_transport=basic" `
  -e "ansible_port=5985" `
  "$Playbook"  # Ex: install_ad_ds.yml
```

**Pourquoi WinRM ?** SSH n'est pas natif sur Windows Server. WinRM = Windows Remote Management (protocole Microsoft).

### 4. Phase Ansible (Configuration applicative)

#### Exemple : Apache (Linux)

**Fichier** : [ansible/playbooks/install_apache.yml](../ansible/playbooks/install_apache.yml)

```yaml
---
- name: Installation Apache + PHP + Site vitrine
  hosts: all
  become: yes

  tasks:
    # [1] Mise à jour système
    - name: apt update
      apt:
        update_cache: yes

    # [2] Installation packages
    - name: Installer Apache + PHP
      apt:
        name:
          - apache2
          - php
          - libapache2-mod-php
        state: present

    # [3] Configuration
    - name: Copier le site web
      copy:
        src: files/index.php
        dest: /var/www/html/

    # [4] Démarrage service
    - name: Démarrer Apache
      systemd:
        name: apache2
        state: started
        enabled: yes
```

#### Exemple : Active Directory (Windows)

**Fichier** : [ansible/playbooks/install_ad_ds.yml](../ansible/playbooks/install_ad_ds.yml)

```yaml
---
- name: Installation Active Directory Domain Services
  hosts: all

  vars:
    domain_name: "gsb.local"
    domain_netbios: "GSB"
    safe_mode_password: "SafeMode123@"

  tasks:
    # [1] Installer le rôle AD DS
    - name: Installer AD-Domain-Services
      win_feature:
        name:
          - AD-Domain-Services
          - RSAT-ADDS
          - DNS
        state: present

    # [2] Promouvoir en contrôleur de domaine
    - name: Créer la forêt AD
      win_domain:
        dns_domain_name: "{{ domain_name }}"
        domain_netbios_name: "{{ domain_netbios }}"
        safe_mode_password: "{{ safe_mode_password }}"
        install_dns: yes
      register: ad_install

    # [3] Redémarrer si nécessaire
    - name: Redémarrer après promotion
      win_reboot:
      when: ad_install.reboot_required

    # [4] Créer des OUs et utilisateurs
    - name: Créer OU Utilisateurs_GSB
      win_domain_ou:
        name: Utilisateurs_GSB
        path: "DC=gsb,DC=local"
```

---

## 🏗️ Architecture des composants

### Fichier de configuration : .env.local

**Localisation** : Racine du projet (ignoré par git)

```bash
# API Proxmox
PROXMOX_API_URL=https://192.168.68.200:8006/api2/json
PROXMOX_TOKEN_ID=root@pam!terraform
PROXMOX_TOKEN_SECRET=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Nœud Proxmox cible
TARGET_NODE=proxmox

# Template LXC Debian
TEMPLATE_NAME=debian-12-standard_12.12-1_amd64.tar.zst

# Stockage
VM_STORAGE=local-lvm

# Clé SSH publique
SSH_KEYS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... terraform-gsb"

# Credentials par défaut
CI_USER=sio2027
CI_PASSWORD=Formation13@

# Windows (Template avec cloudbase-init)
WINDOWS_TEMPLATE_ID=WSERVER-TEMPLATE
WINDOWS_ADMIN_PASSWORD=Admin123@
```

**Sécurité** : Ce fichier contient des **secrets** → `.gitignore`

### Scripts utilitaires

#### scripts/common.sh (Nouveau !)

**Fonctions partagées** par tous les scripts :

```bash
# Couleurs
export BLUE='\033[0;34m'
export GREEN='\033[0;32m'
# ...

# Messages
success() { echo -e "${GREEN}✓ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}" >&2; exit "${2:-1}"; }
info() { echo -e "${CYAN}→ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠  $1${NC}"; }

# Retry logic
retry_command() {
    local max_attempts=$1
    local sleep_time=$2
    shift 2

    for attempt in {1..$max_attempts}; do
        if "$@" 2>/dev/null; then return 0; fi
        [ $attempt -eq $max_attempts ] && return 1
        sleep "$sleep_time"
    done
}

# Chemins calculés automatiquement
export PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export TERRAFORM_DIR="$PROJECT_ROOT/terraform"
export ANSIBLE_DIR="$PROJECT_ROOT/ansible"
export SSH_KEY="$PROJECT_ROOT/ssh/id_ed25519_terraform"
```

**Avantages** :
- ✅ Code DRY (Don't Repeat Yourself)
- ✅ Modifier les couleurs → 1 seul fichier
- ✅ Fonction `retry_command()` réutilisable
- ✅ Gestion d'erreur unifiée

#### scripts/create_autounattend_iso.sh

**Rôle** : Créer un ISO contenant `autounattend.xml` pour l'installation automatique de Windows.

```bash
# [1] Vérifier genisoimage/mkisofs
ISO_CMD=$(command -v genisoimage || command -v mkisofs)

# [2] Copier autounattend.xml dans un dossier temporaire
TEMP_DIR=$(mktemp -d)
cp "$TERRAFORM_DIR/autounattend.xml" "$TEMP_DIR/"

# [3] Créer l'ISO
$ISO_CMD -o "$TERRAFORM_DIR/autounattend.iso" \
    -J -R -V "AUTOUNATTEND" \
    -input-charset utf-8 \
    "$TEMP_DIR"

# [4] Nettoyer
rm -rf "$TEMP_DIR"
```

**Format ISO** :
- `-J` : Joliet (long noms de fichiers)
- `-R` : Rock Ridge (permissions UNIX)
- `-V` : Label du volume

#### scripts/prepare_windows_iso.sh

**Rôle** : Wrapper qui crée l'ISO + upload sur Proxmox via API.

```bash
# [1] Créer l'ISO
./create_autounattend_iso.sh

# [2] Upload via API Proxmox
curl -X POST "$API_BASE_URL/api2/json/nodes/$TARGET_NODE/storage/local/upload" \
    -F "content=iso" \
    -F "filename=@$TERRAFORM_DIR/autounattend.iso"

# [3] Vérifier disponibilité
curl "$API_BASE_URL/api2/json/nodes/$TARGET_NODE/storage/local/content" | \
    grep "autounattend.iso"
```

---

## 🔧 Détails techniques

### Pourquoi Terraform + Ansible ?

| Outil     | Rôle                          | Pourquoi                                  |
|-----------|-------------------------------|-------------------------------------------|
| Terraform | Infrastructure (VMs/containers) | Gère l'état (state), idempotent, API-first |
| Ansible   | Configuration (packages, apps) | Déclaratif, large écosystème de modules   |

**Séparation des responsabilités** :
- Terraform = "Créer la machine"
- Ansible = "Installer et configurer l'application"

### Communication avec Proxmox

#### API REST

**Base URL** : `https://IP_PROXMOX:8006/api2/json`

**Authentification** : API Token

```bash
Authorization: PVEAPIToken=root@pam!terraform=xxxxxxxx-xxxx-...
```

**Endpoints utilisés** :

| Endpoint | Méthode | Usage |
|----------|---------|-------|
| `/cluster/nextid` | GET | Récupérer le prochain VMID disponible |
| `/nodes/{node}/lxc` | POST | Créer un container LXC |
| `/nodes/{node}/qemu` | POST | Créer une VM QEMU |
| `/nodes/{node}/qemu/{vmid}/status/start` | POST | Démarrer une VM |
| `/nodes/{node}/lxc/{vmid}/interfaces` | GET | Récupérer l'IP du container |
| `/nodes/{node}/qemu/{vmid}/agent/network-get-interfaces` | GET | Récupérer l'IP de la VM (via agent) |

**Exemple de création de VM** :

```bash
curl -k -s \
  -H "Authorization: PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}" \
  -X POST "https://proxmox:8006/api2/json/nodes/proxmox/qemu" \
  --data-urlencode "vmid=100" \
  --data-urlencode "name=gsb-dc" \
  --data-urlencode "cores=4" \
  --data-urlencode "memory=4096" \
  --data-urlencode "bios=ovmf" \
  --data-urlencode "efidisk0=local-lvm:1,efitype=4m" \
  --data-urlencode "scsi0=local-lvm:60" \
  --data-urlencode "ide2=drive:iso/SERVER_EVAL.iso,media=cdrom"
```

### QEMU Guest Agent

**Rôle** : Programme dans la VM qui expose des infos au host Proxmox (IP, hostname, etc.)

**Installation automatique** :
- LXC : Intégré par défaut
- Windows : Via le playbook Ansible (`win_package: qemu-guest-agent.msi`)

**Pourquoi c'est critique ?** Sans agent, impossible de récupérer l'IP de la VM Windows automatiquement.

### Gestion des clés SSH

**Génération** (une seule fois) :

```bash
ssh-keygen -t ed25519 -f ssh/id_ed25519_terraform -N ""
```

**Clés** :
- `ssh/id_ed25519_terraform` : Clé **privée** (ignorée par git)
- `ssh/id_ed25519_terraform.pub` : Clé **publique** (ignorée par git)

**Injection dans les containers** :

Via Terraform → variable `ssh_keys` → Cloud-init → `/root/.ssh/authorized_keys`

**Usage** :

```bash
ssh -i ssh/id_ed25519_terraform root@IP_CONTAINER
```

### Parsing JSON dans Bash

**Problème** : L'API Proxmox retourne du JSON, mais `jq` n'est pas toujours installé.

**Solution** : Regex avec `grep`

Exemple : Récupérer le VMID depuis `{"data":"100"}`

```bash
# ⚠️ L'API retourne "100" (string) et pas 100 (number)
VMID=$(echo "$RESPONSE" | grep -oE '"data"[[:space:]]*:[[:space:]]*"?[0-9]+"?' | grep -oE '[0-9]+')
```

**Pattern** : `"?[0-9]+"?` → Gère à la fois `"100"` et `100`

---

## 📦 Cas d'usage par service

### 1. Apache + PHP (Linux)

**Commande** :
```bash
./setup.sh → [1] Apache + PHP
```

**Flux** :
1. Terraform crée un container LXC Debian 12
2. Cloud-init configure l'utilisateur + SSH
3. `provision.sh` attend SSH disponible
4. Ansible exécute `install_apache.yml` :
   - `apt update`
   - `apt install apache2 php libapache2-mod-php`
   - Copie `index.php` dans `/var/www/html/`
   - `systemctl start apache2`
5. **Résultat** : Site accessible sur `http://IP_CONTAINER`

### 2. MySQL / MariaDB (Linux)

**Commande** :
```bash
./setup.sh → [2] MySQL / MariaDB
```

**Flux** :
1. Container LXC créé
2. Ansible exécute `install_mysql.yml` :
   - `apt install mariadb-server`
   - Configure `bind-address = 0.0.0.0` (écoute sur toutes les interfaces)
   - Crée une base `gsb_db`
   - Crée un utilisateur `gsb_user` / `password`
   - `GRANT ALL PRIVILEGES ON gsb_db.*`
3. **Résultat** : MySQL accessible sur port 3306

### 3. Uptime Kuma (Monitoring)

**Commande** :
```bash
./setup.sh → [3] Uptime Kuma
```

**Spécificité** : Application Node.js

**Flux** :
1. Container LXC créé
2. Ansible exécute `install_uptime_kuma.yml` :
   - `apt install nodejs npm git`
   - `git clone https://github.com/louislam/uptime-kuma.git`
   - `npm install --production`
   - Crée un service systemd : `/etc/systemd/system/uptime-kuma.service`
   - `systemctl start uptime-kuma`
3. **Résultat** : Interface web sur `http://IP:3001`

**Credentials** : `admin` / `admin123` (premier accès)

### 4. AdGuard Home (DNS + Ad blocker)

**Commande** :
```bash
./setup.sh → [4] AdGuard Home
```

**Flux** :
1. Container LXC créé
2. Ansible exécute `install_adguard.yml` :
   - Télécharge le binaire AdGuard depuis GitHub releases
   - Installe dans `/opt/AdGuardHome/`
   - Configure le service systemd
   - Démarre AdGuard
3. **Résultat** :
   - Interface web : `http://IP:3000`
   - DNS : `IP:53`

**Configuration initiale** : Via l'interface web (wizard)

### 5. Active Directory (Windows Server)

**Commande** :
```bash
./setup.sh → [5] Active Directory
```

**Spécificité** : VM QEMU (Windows Server 2022)

**Flux** :
1. Terraform crée une VM QEMU avec :
   - BIOS UEFI (`bios=ovmf`)
   - Disque EFI (`efidisk0`)
   - ISO Windows Server monté
2. **Installation Windows** :
   - Manuelle (via console Proxmox)
   - OU Automatique (si `autounattend.iso` monté)
3. **Configuration WinRM** (dans Windows) :
   ```powershell
   Enable-PSRemoting -Force
   Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
   Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
   ```
4. `provision_windows.ps1` attend WinRM disponible
5. Ansible exécute `install_ad_ds.yml` :
   - `win_feature: AD-Domain-Services`
   - `win_domain: create forest gsb.local`
   - Redémarrage automatique
   - Création OUs, groupes, utilisateurs
6. **Résultat** :
   - Domaine : `gsb.local`
   - Accès RDP : `IP:3389`
   - Credentials : `Administrator` / `Admin123@`

**Structure AD créée** :
```
DC=gsb,DC=local
├── OU=Utilisateurs_GSB
│   ├── admin.gsb
│   ├── user1.gsb
│   ├── user2.gsb
│   └── user3.gsb
├── OU=Ordinateurs_GSB
└── OU=Serveurs_GSB
```

---

## 🔐 Sécurité

### Mots de passe par défaut

**⚠️ ATTENTION** : Tous les mots de passe sont des **exemples pour développement**.

| Service | User | Password |
|---------|------|----------|
| Containers Linux | `sio2027` | `Formation13@` |
| MySQL | `gsb_user` | `Formation13@` |
| Uptime Kuma | `admin` | `admin123` |
| AdGuard | Configuration initiale | - |
| Windows Admin | `Administrator` | `Admin123@` |
| AD Domain Admin | `admin.gsb` | `Admin123@` |

**Production** : CHANGER TOUS LES MOTS DE PASSE !

### Fichiers sensibles (ignorés par git)

```
.env.local                      # Credentials Proxmox
terraform/terraform.tfvars      # Variables Terraform
terraform/terraform.tfstate     # État (contient IPs, IDs)
ssh/id_ed25519_terraform        # Clé privée SSH
ssh/id_ed25519_terraform.pub    # Clé publique SSH
```

### WinRM (Windows)

**Configuration actuelle** : `Basic Auth` + `AllowUnencrypted`

**⚠️ Risque** : Authentification en clair sur le réseau

**Production** :
1. Utiliser HTTPS (port 5986)
2. Certificat SSL
3. Authentification Kerberos ou NTLM

---

## 🐛 Debugging

### Logs Terraform

```bash
cd terraform
export TF_LOG=DEBUG
terraform apply
```

### Logs Ansible

```bash
ansible-playbook -vvv playbook.yml
```

### Connexion manuelle SSH

```bash
ssh -i ssh/id_ed25519_terraform root@IP_CONTAINER
```

### Test WinRM (Windows)

```powershell
Test-WSMan -ComputerName IP_VM
```

### Logs Proxmox (sur le serveur)

```bash
ssh root@proxmox
tail -f /var/log/pve/tasks/active
```

---

## 📚 Ressources

### Documentation officielle
- [Proxmox API](https://pve.proxmox.com/pve-docs/api-viewer/)
- [Terraform Proxmox Provider](https://registry.terraform.io/providers/Telmate/proxmox/latest/docs)
- [Ansible Documentation](https://docs.ansible.com/)
- [Ansible Windows Modules](https://docs.ansible.com/ansible/latest/collections/ansible/windows/)

### Fichiers du projet
- [README.md](../README.md) - Guide utilisateur
- [docs/WINDOWS.md](WINDOWS.md) - Guide Windows/AD détaillé
- [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Dépannage

---

**Dernière mise à jour** : 2025-12-20
**Auteur** : Claude Sonnet 4.5 (avec supervision utilisateur)
