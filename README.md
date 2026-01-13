# 🚀 Auto GSB - Déploiement automatique Proxmox

Système automatisé pour créer et configurer des containers LXC et VMs sur Proxmox avec installation automatique de services via Terraform + Ansible.

## 📋 Services disponibles

| Service | Type | Description |
|---------|------|-------------|
| **Apache** | LXC | Serveur web HTTP |
| **MySQL** | LXC | Base de données |
| **Uptime Kuma** | LXC | Monitoring de services |
| **Active Directory** | QEMU | Contrôleur de domaine Windows Server 2022 |

## ⚡ Démarrage rapide

### 1. Configurer l'accès Proxmox

```bash
cp .env.local.example .env.local
nano .env.local
```

Remplir :
```bash
PROXMOX_API_URL=https://192.168.68.200:8006/api2/json
PROXMOX_TOKEN_ID=root@pam!terraform
PROXMOX_TOKEN_SECRET=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
TARGET_NODE=proxmox
```

**Créer un token API** : Proxmox → Datacenter → Permissions → API Tokens → Add

### 2. Déployer des services

```bash
./setup.sh
```

Le script vous guide étape par étape :
1. Sélection des services à installer
2. Configuration des ressources (CPU, RAM, Disque)
3. Résumé et confirmation
4. Déploiement automatique

### 3. Nettoyer

```bash
./cleanup.sh
```

Supprime tous les containers et VMs créés.

## 🔧 Prérequis

### Système local
- Terraform >= 1.0
- Ansible >= 2.9
- PowerShell Core (pour Windows Server)
- Python + pywinrm (pour Windows Server)

```bash
# macOS
brew install terraform ansible pwsh
pip3 install --break-system-packages pywinrm

# Linux
sudo apt install terraform ansible
pip3 install pywinrm
```

### Proxmox
- Proxmox VE >= 7.0
- Template LXC Debian 12 téléchargé
- ISO Windows Server (pour Active Directory)
- API Token créé

## 📁 Structure du projet

```
auto_gsb/
├── README.md                    # Ce fichier
├── setup.sh                     # Script principal
├── cleanup.sh                   # Script de nettoyage
│
├── docs/                        # Documentation
│   ├── WINDOWS-SETUP-GUIDE.md  # Guide Windows/AD (cloud-init)
│   ├── windows-template-setup.md # Création template Windows
│   ├── ARCHITECTURE.md          # Architecture du projet
│   └── TROUBLESHOOTING.md       # Dépannage
│
├── scripts/                     # Scripts
│   ├── provision.sh            # Provisioning Linux
│   ├── provision_windows.ps1   # Provisioning Windows
│   └── create_autounattend_iso.sh
│
├── terraform/                   # Infrastructure
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── autounattend.xml
│
├── ansible/                     # Configuration
│   ├── ansible.cfg
│   └── playbooks/
│       ├── install_apache.yml
│       ├── install_mysql.yml
│       ├── install_uptime_kuma.yml
│       └── install_ad_ds.yml
│
└── .env.local.example          # Template config
```

## 🐧 Services Linux (LXC)

### Apache

```bash
./setup.sh
# Sélectionner [1] Apache
```

**Accès** : `http://<IP_CONTAINER>`

**Credentials** : `sio2027 / Formation13@`

### MySQL

```bash
./setup.sh
# Sélectionner [2] MySQL
```

**Accès** : `mysql -h <IP_CONTAINER> -u root -p`

**Root password** : `rootpassword`

### Uptime Kuma

```bash
./setup.sh
# Sélectionner [4] Uptime Kuma
```

**Accès** : `http://<IP_CONTAINER>:3001`

**Premier démarrage** : Créer un compte admin

## 🪟 Windows Server / Active Directory

Pour déployer Active Directory sur Windows Server 2022 avec cloud-init, consultez le guide complet :

**📖 [docs/WINDOWS-SETUP-GUIDE.md](docs/WINDOWS-SETUP-GUIDE.md)**

### Processus en 2 étapes :

1. **Créer le template Windows** (une seule fois, ~45 min)
   - Guide : [docs/windows-template-setup.md](docs/windows-template-setup.md)

2. **Déployer avec Terraform** (5-10 min par VM)
   ```bash
   cd terraform
   terraform apply
   ```

**Avantages** :
- ✅ Déploiement en 5-10 min (vs 30-40 min avec ISO)
- ✅ Configuration via cloud-init (comme les LXC)
- ✅ Réutilisable pour toutes les VMs Windows
- ✅ Installation AD DS automatique au premier boot

**Domaine** : `gsb.local`
**Admin** : `admin.gsb@gsb.local / Admin123@`

## 🔍 Commandes utiles

### Lister les ressources déployées

```bash
cd terraform
terraform state list
```

### Voir les détails d'une ressource

```bash
terraform state show proxmox_lxc.container[\"apache\"]
```

### Accéder à un container

```bash
ssh -i ssh/id_ed25519_terraform root@<IP_CONTAINER>
```

### Relancer Ansible sur un container

```bash
cd ansible
ansible-playbook -i <IP>, -u root playbooks/install_apache.yml
```

## 🛠️ Dépannage

Consultez le guide de dépannage complet :

**📖 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**

### Erreurs courantes

**Terraform : "template not found"**
```bash
# Télécharger le template Debian 12 dans Proxmox
# Storage → local → CT Templates → Download → debian-12-standard
```

**Ansible : "SSH connection failed"**
```bash
# Attendre quelques secondes que le container démarre
# Vérifier la clé SSH
ls -la ssh/id_ed25519_terraform*
```

**Windows : "WinRM connection failed"**
```bash
# Activer WinRM dans la VM Windows :
Enable-PSRemoting -Force
```

## 📚 Documentation complète

- **[docs/WINDOWS-SETUP-GUIDE.md](docs/WINDOWS-SETUP-GUIDE.md)** - Guide complet Windows Server et Active Directory (cloud-init)
- **[docs/windows-template-setup.md](docs/windows-template-setup.md)** - Création du template Windows avec cloudbase-init
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** - Architecture et flux du projet
- **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** - Dépannage et solutions aux erreurs

## 🔐 Sécurité

**⚠️ ATTENTION** : Cette configuration est pour **démonstration et apprentissage** uniquement !

Pour la production :
- ✅ Changer TOUS les mots de passe par défaut
- ✅ Utiliser des clés SSH dédiées
- ✅ Configurer le pare-feu
- ✅ Activer HTTPS avec certificats valides
- ✅ Limiter les accès réseau

## 📄 Licence

Projet éducatif - GSB Formation

## 🤝 Contribution

Ce projet est utilisé dans un cadre pédagogique. Pour toute question ou amélioration, contactez votre formateur.

---

**Auteur** : Formation SIO 2027
**Version** : 2.0
**Dernière mise à jour** : Décembre 2024
