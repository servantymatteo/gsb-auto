# 🔧 Guide de dépannage

Solutions aux erreurs courantes rencontrées lors du déploiement.

## 📋 Table des matières

- [Erreurs Terraform](#-erreurs-terraform)
- [Erreurs Ansible](#-erreurs-ansible)
- [Problèmes Réseau](#-problèmes-réseau)
- [Problèmes Windows / WinRM](#-problèmes-windows--winrm)
- [Problèmes Proxmox](#-problèmes-proxmox)

---

## 🏗️ Erreurs Terraform

### "template not found" ou "template does not exist"

**Erreur** :
```
Error: template 'debian-12-standard_12.12-1_amd64.tar.zst' does not exist
```

**Cause** : Le template LXC n'est pas téléchargé dans Proxmox.

**Solution** :
1. Proxmox → Storage → local (proxmox)
2. CT Templates
3. Templates → Download
4. Chercher : `debian-12-standard`
5. Télécharger la dernière version

**Vérification** :
```bash
ssh root@proxmox
pveam list local | grep debian-12
```

### "API connection failed" ou "401 Unauthorized"

**Erreur** :
```
Error: error during API call: 401 Unauthorized
```

**Causes** :
- Token API invalide
- Token expiré
- Permissions insuffisantes

**Solution** :
1. Vérifier `.env.local` :
   ```bash
   cat .env.local | grep TOKEN
   ```
2. Recréer le token dans Proxmox :
   - Datacenter → Permissions → API Tokens
   - Sélectionner l'ancien token → Remove
   - Add → root@pam → Nom : terraform
   - Cocher : **Privilege Separation** = NO
   - Copier le secret dans `.env.local`

### "VMID already exists"

**Erreur** :
```
Error: VMID 100 already exists
```

**Cause** : Un container/VM avec le même VMID existe déjà.

**Solution** :
```bash
# Lister les VMs existantes
ssh root@proxmox
qm list

# Supprimer la VM en conflit
qm destroy <VMID>

# Ou modifier le VMID dans Terraform
cd terraform
terraform apply
```

### "Invalid format - efidisk0"

**Erreur** :
```
Error: invalid format - efidisk0
```

**Cause** : Le provider Proxmox ne supporte pas efidisk.

**Solution** : Déjà corrigé dans le code. Si l'erreur persiste :
```bash
cd terraform
terraform init -upgrade
terraform apply
```

### "Parsing JSON with quotes"

**Erreur** :
```
ERREUR: Impossible de récupérer le prochain VMID
Réponse complète: {"data":"100"}
```

**Cause** : L'API Proxmox retourne des nombres entre guillemets.

**Solution** : Déjà corrigé dans `main.tf`. Vérifier la version :
```bash
cd terraform
grep -n '"?[0-9]+"?' main.tf
# Devrait afficher des lignes avec "?[0-9]+"?
```

---

## 🎭 Erreurs Ansible

### "SSH connection failed" ou "SSH timeout"

**Erreur** :
```
fatal: [IP]: UNREACHABLE! => {"msg": "Failed to connect to the host via ssh"}
```

**Causes** :
1. Container pas encore démarré
2. Clé SSH incorrecte
3. Permissions clé SSH
4. Pare-feu

**Solutions** :

1. **Attendre le démarrage** :
   ```bash
   # Vérifier que le container tourne
   ssh root@proxmox
   pct status <VMID>

   # Redémarrer si nécessaire
   pct start <VMID>
   ```

2. **Vérifier les clés SSH** :
   ```bash
   ls -la ssh/id_ed25519_terraform*
   # Devrait afficher 2 fichiers

   # Permissions correctes
   chmod 600 ssh/id_ed25519_terraform
   chmod 644 ssh/id_ed25519_terraform.pub
   ```

3. **Test manuel SSH** :
   ```bash
   ssh -i ssh/id_ed25519_terraform root@<IP_CONTAINER>
   ```

4. **Vérifier la clé publique dans le container** :
   ```bash
   ssh root@proxmox
   pct enter <VMID>
   cat ~/.ssh/authorized_keys
   # Devrait contenir la clé publique
   ```

### "ansible-playbook: command not found"

**Erreur** :
```
ansible-playbook: command not found
```

**Solution** :
```bash
# macOS
brew install ansible

# Linux
sudo apt install ansible

# Vérification
ansible-playbook --version
```

### "Module not found: community.general"

**Erreur** :
```
ERROR! couldn't resolve module/action 'community.general.mysql_db'
```

**Solution** :
```bash
ansible-galaxy collection install community.general
ansible-galaxy collection install community.mysql
```

### "Playbook not found"

**Erreur** :
```
ERROR! the playbook: ../ansible/playbooks/install_apache.yml could not be found
```

**Solution** :
```bash
# Vérifier que le playbook existe
ls -la ansible/playbooks/

# Vérifier le chemin relatif
pwd
# Doit être dans /path/to/auto_gsb
```

---

## 🌐 Problèmes Réseau

### "IP non trouvée" ou "IP non disponible"

**Erreur** :
```
IP non disponible pour le container
```

**Causes** :
1. DHCP pas configuré
2. Container pas encore démarré
3. Réseau bridge incorrect

**Solutions** :

1. **Vérifier la configuration réseau** :
   ```bash
   ssh root@proxmox
   pct config <VMID> | grep net0
   # Devrait afficher: net0: name=eth0,bridge=vmbr0,ip=dhcp
   ```

2. **Vérifier le bridge** :
   ```bash
   ip link show vmbr0
   # Devrait être UP
   ```

3. **Récupérer l'IP manuellement** :
   ```bash
   pct exec <VMID> -- ip addr show eth0
   ```

4. **Redémarrer le container** :
   ```bash
   pct restart <VMID>
   sleep 10
   pct exec <VMID> -- ip addr show eth0
   ```

### "Cannot ping container"

**Vérifications** :

```bash
# Depuis Proxmox
ssh root@proxmox
ping <IP_CONTAINER>

# Depuis le container
pct enter <VMID>
ping 8.8.8.8
ping gateway

# Vérifier les routes
ip route
```

---

## 🪟 Problèmes Windows / WinRM

### "WinRM connection failed"

**Erreur** :
```
fatal: [IP]: UNREACHABLE! => {"msg": "winrm or requests is not installed"}
```

**Solutions** :

1. **Installer pywinrm** :
   ```bash
   pip3 install --break-system-packages pywinrm

   # Vérification
   python3 -c "import winrm; print('OK')"
   ```

2. **Vérifier WinRM dans Windows** (via console Proxmox) :
   ```powershell
   Get-Service WinRM
   # Doit être Running

   # Si Stopped :
   Start-Service WinRM
   Enable-PSRemoting -Force
   ```

3. **Test WinRM depuis votre machine** :
   ```bash
   nc -zv <IP_VM> 5985
   # Devrait afficher: Connection to IP 5985 port [tcp/*] succeeded!
   ```

4. **Vérifier le pare-feu Windows** :
   ```powershell
   Get-NetFirewallRule -Name "WinRM*" | Select Name, Enabled

   # Si désactivé :
   Enable-NetFirewallRule -Name "WINRM-HTTP-In-TCP"
   ```

### "Basic authentication is disabled"

**Erreur** :
```
the specified credentials were rejected by the server
```

**Solution dans Windows** :
```powershell
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true

# Redémarrer WinRM
Restart-Service WinRM
```

### "PowerShell not found (pwsh)"

**Erreur** :
```
pwsh: command not found
```

**Solution** :
```bash
# macOS
brew install --cask powershell

# Linux
wget https://github.com/PowerShell/PowerShell/releases/download/v7.4.0/powershell_7.4.0-1.deb_amd64.deb
sudo dpkg -i powershell_7.4.0-1.deb_amd64.deb

# Vérification
pwsh --version
```

### "Windows installation stuck"

**Symptôme** : Installation Windows bloquée sur la sélection de la langue.

**Cause** : `autounattend.xml` non détecté.

**Solutions** :

1. **Continuer manuellement** :
   - Installer Windows via la console
   - Activer WinRM
   - Lancer Ansible manuellement

2. **Vérifier l'ISO autounattend** :
   ```bash
   # Sur Proxmox
   ssh root@proxmox
   ls -lh /var/lib/vz/template/iso/autounattend.iso

   # Vérifier qu'il est monté
   qm config <VMID> | grep ide3
   # Devrait afficher: ide3: local:iso/autounattend.iso,media=cdrom
   ```

3. **Recréer l'ISO** :
   ```bash
   cd scripts
   ./create_autounattend_iso.sh
   scp ../terraform/autounattend.iso root@proxmox:/var/lib/vz/template/iso/
   ```

---

## 🖥️ Problèmes Proxmox

### "Cannot connect to Proxmox API"

**Erreur** :
```
Error: error during API call: dial tcp: lookup proxmox: no such host
```

**Solutions** :

1. **Vérifier l'URL dans `.env.local`** :
   ```bash
   cat .env.local | grep PROXMOX_API_URL
   # Doit être: https://IP:8006/api2/json
   ```

2. **Test de connectivité** :
   ```bash
   ping 192.168.68.200
   curl -k https://192.168.68.200:8006
   ```

3. **Vérifier le certificat SSL** :
   ```bash
   curl -k https://192.168.68.200:8006/api2/json/version
   ```

### "Storage not found"

**Erreur** :
```
Error: storage 'local-lvm' does not exist
```

**Solution** :

1. **Lister les storages disponibles** :
   ```bash
   ssh root@proxmox
   pvesm status
   ```

2. **Modifier `.env.local`** :
   ```bash
   VM_STORAGE=<nom_du_storage>
   # Exemples: local-lvm, local-zfs, pve-storage
   ```

### "VM is locked"

**Erreur** :
```
Error: VM is locked (destroy)
```

**Solution** :
```bash
ssh root@proxmox
qm unlock <VMID>
qm destroy <VMID>
```

---

## 🔍 Commandes de diagnostic

### Vérifier l'état général

```bash
# Terraform
cd terraform
terraform state list
terraform show

# Ansible
ansible --version
ansible-galaxy collection list

# Proxmox
ssh root@proxmox
pct list
qm list
```

### Logs utiles

```bash
# Terraform
export TF_LOG=DEBUG
terraform apply

# Ansible
ansible-playbook -vvv playbook.yml

# Proxmox container logs
ssh root@proxmox
pct enter <VMID>
journalctl -xe

# Proxmox VM logs
tail -f /var/log/pve/tasks/active
```

### Tests de connectivité

```bash
# API Proxmox
curl -k -H "Authorization: PVEAPIToken=TOKEN_ID=SECRET" \
  https://PROXMOX_IP:8006/api2/json/version

# SSH vers container
ssh -i ssh/id_ed25519_terraform root@CONTAINER_IP

# WinRM vers Windows
Test-WSMan -ComputerName VM_IP
```

---

## 🆘 Réinitialisation complète

Si tout est cassé, voici comment repartir de zéro :

```bash
# 1. Supprimer toutes les ressources
./cleanup.sh

# 2. Nettoyer l'état Terraform
cd terraform
rm -rf .terraform terraform.tfstate* .terraform.lock.hcl
terraform init

# 3. Vérifier la configuration
cd ..
cat .env.local

# 4. Recommencer
./setup.sh
```

---

**Problème non résolu ?** Consultez la [documentation Proxmox](https://pve.proxmox.com/wiki/Main_Page) ou [Terraform Proxmox Provider](https://registry.terraform.io/providers/Telmate/proxmox/latest/docs).
