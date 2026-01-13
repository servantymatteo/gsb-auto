# 🚀 Déploiement Local sur Proxmox

Ce guide explique comment déployer les containers Linux directement sur le serveur Proxmox (sans Windows Server).

---

## 📋 Prérequis

1. **Accès SSH au serveur Proxmox** (en tant que root)
2. **Terraform installé** sur le serveur Proxmox
3. **Ansible installé** sur le serveur Proxmox
4. **Template Debian 12** disponible dans Proxmox

---

## 🔧 Installation (une seule fois)

### 1. Se connecter au serveur Proxmox

```bash
ssh root@192.168.68.200
```

### 2. Installer Terraform

```bash
# Télécharger Terraform
wget https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip

# Installer unzip si nécessaire
apt update && apt install -y unzip

# Extraire et installer
unzip terraform_1.7.0_linux_amd64.zip
mv terraform /usr/local/bin/
chmod +x /usr/local/bin/terraform

# Vérifier
terraform version
```

### 3. Installer Ansible

```bash
apt update
apt install -y ansible python3-pip

# Vérifier
ansible --version
```

### 4. Copier le projet sur Proxmox

```bash
# Créer un répertoire
mkdir -p /root/auto_gsb
cd /root/auto_gsb

# Option 1: Cloner depuis git (si vous avez un repo)
git clone <url-du-repo> .

# Option 2: Copier depuis votre Mac
# Sur votre Mac, exécutez:
# scp -r /Users/matteoservanty/dev/auto_gsb/* root@192.168.68.200:/root/auto_gsb/
```

### 5. Configurer les variables

```bash
cd /root/auto_gsb

# Copier le fichier de configuration
cp .env.local.proxmox .env.local

# Éditer avec vos valeurs
nano .env.local
```

Exemple de configuration:
```bash
TARGET_NODE=proxmox
TEMPLATE_NAME=debian-12-standard_12.12-1_amd64.tar.zst
VM_STORAGE=local-lvm
SSH_KEYS="votre-clé-publique-ssh"
CI_USER=sio2027
CI_PASSWORD=Formation13@
PM_USER=root@pam
PM_PASSWORD=votre-mot-de-passe-root
```

### 6. Vérifier le template Debian

```bash
# Lister les templates disponibles
pveam list local

# Si le template n'existe pas, le télécharger
pveam download local debian-12-standard_12.12-1_amd64.tar.zst
```

---

## 🎯 Utilisation

### Lancer le déploiement

```bash
cd /root/auto_gsb

# Rendre le script exécutable
chmod +x deploy_local.sh

# Lancer le script
./deploy_local.sh
```

### Menu interactif

Le script affichera un menu:

```
Services disponibles:
  1) Apache + PHP
  2) MySQL / MariaDB
  3) Uptime Kuma (Monitoring)
  4) AdGuard Home (DNS + Ad Blocker)
  5) Tous les services ci-dessus
  0) Quitter

Votre choix:
```

### Exemple de déploiement

```bash
# Choisir "1" pour Apache
Votre choix: 1

# Donner un nom
Nom de base pour les VMs (défaut: GSB): MONSITE

# Confirmer
Continuer avec cette configuration? (o/N): o

# Appliquer
Appliquer les changements? (o/N): o
```

---

## 📊 Services disponibles

| Service | Description | Ressources | Port |
|---------|-------------|------------|------|
| Apache + PHP | Serveur web avec PHP | 2 CPU, 2GB RAM, 10GB disk | 80 |
| MySQL | Base de données | 2 CPU, 2GB RAM, 15GB disk | 3306 |
| Uptime Kuma | Monitoring/Supervision | 2 CPU, 2GB RAM, 15GB disk | 3001 |
| AdGuard Home | DNS + Bloqueur de pub | 1 CPU, 1GB RAM, 8GB disk | 3000, 53 |

---

## 🔍 Vérification

### Voir les containers créés

```bash
pct list
```

### Voir les adresses IP

```bash
# Depuis le répertoire terraform
cd /root/auto_gsb/terraform
terraform output
```

### Se connecter à un container

```bash
# Par SSH (avec la clé)
ssh -i ~/.ssh/id_ed25519 sio2027@<IP_CONTAINER>

# Ou directement
pct enter <VMID>
```

---

## 🧹 Nettoyage

### Détruire tous les containers

```bash
cd /root/auto_gsb
./cleanup.sh
```

### Détruire un container spécifique

```bash
cd /root/auto_gsb/terraform
terraform destroy -target='proxmox_lxc.container["apache"]'
```

---

## 🐛 Dépannage

### Terraform ne trouve pas le template

```bash
# Vérifier le nom exact du template
pveam list local

# Mettre à jour TEMPLATE_NAME dans .env.local
```

### Erreur d'authentification

```bash
# Vérifier le mot de passe root dans .env.local
# S'assurer que PM_USER=root@pam et PM_PASSWORD sont corrects
```

### Container ne démarre pas

```bash
# Voir les logs
pct config <VMID>
journalctl -xe

# Voir le statut
pct status <VMID>
```

---

## 📝 Notes importantes

- ⚠️ Ce script déploie **uniquement les containers Linux**
- ⚠️ Windows Server n'est **pas inclus** dans ce déploiement
- ✅ Exécution **directement sur Proxmox** (pas depuis un PC distant)
- ✅ Utilise l'**authentification locale** (mot de passe root)
- ✅ Pas besoin de **token API**

---

## 🔗 Documentation complète

- [README principal](README.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
