# Auto GSB

Automatisation de déploiement d'une infrastructure GSB sur Proxmox avec Terraform, Ansible, scripts shell et un configurateur React.

Le projet permet de :

- préparer la configuration Proxmox via `.env.local`
- déployer des conteneurs Linux LXC depuis un template Debian
- déployer une VM Windows Server pour Active Directory depuis un template Proxmox
- provisionner automatiquement les services via Ansible
- générer les fichiers de configuration depuis une interface web React

## Services supportés

- Apache
- GLPI
- Uptime Kuma
- AdGuard Home
- Active Directory Domain Services

## Structure du projet

```text
.
├── ansible/
│   ├── playbooks/
│   └── vars/
├── scripts/
├── terraform/
└── web/configurator-react/
```

## Prérequis

Exécution recommandée sur un serveur Proxmox.

- Proxmox VE accessible via API
- `git`
- `curl`
- `terraform`
- `ansible-playbook`
- `pwsh` pour le provisioning Windows
- un template LXC Debian disponible sur Proxmox
- un template Windows Server avec Cloudbase-Init pour Active Directory

## Flux principal

### 1. Bootstrap initial

Depuis le serveur Proxmox :

```bash
curl -fsSL https://raw.githubusercontent.com/servantymatteo/gsb-auto/local/install.sh | bash
```

`install.sh` :

- vérifie que la machine est bien un hôte Proxmox
- synchronise le dépôt avec GitHub
- peut créer automatiquement un token API Proxmox si l'exécution est faite en `root`
- relance le script depuis le dossier d'installation final si nécessaire

### 2. Configuration

```bash
./setup.sh
```

Le script :

- charge ou crée `.env.local`
- propose un assistant interactif pour renseigner les variables Proxmox et Windows
- initialise Terraform
- applique la configuration dans `terraform/`

Pour ne configurer que l'environnement :

```bash
./setup.sh --env-only
```

### 3. Déploiement

Le déploiement s'appuie sur :

- [`terraform/main.tf`](/Users/matteoservanty/dev/auto_gsb/terraform/main.tf) pour créer les LXC et les VMs
- [`scripts/provision.sh`](/Users/matteoservanty/dev/auto_gsb/scripts/provision.sh) pour le provisioning Linux via SSH + Ansible
- [`scripts/provision_windows.ps1`](/Users/matteoservanty/dev/auto_gsb/scripts/provision_windows.ps1) pour le provisioning Windows via WinRM

## Fichiers de configuration

### `.env.local`

Variables principales attendues :

- `PROXMOX_API_URL`
- `PROXMOX_TOKEN_ID`
- `PROXMOX_TOKEN_SECRET`
- `TARGET_NODE`
- `TEMPLATE_NAME`
- `VM_STORAGE`
- `VM_NETWORK_BRIDGE`
- `SSH_KEYS`
- `CI_USER`
- `CI_PASSWORD`
- `WINDOWS_TEMPLATE_ID`
- `WINDOWS_ADMIN_PASSWORD`

### `terraform/terraform.tfvars`

Le fichier décrit les machines à créer avec la map `vms`, par exemple :

```hcl
vms = {
  "web" = {
    cores     = 2
    memory    = 2048
    disk_size = "10G"
    playbook  = "install_apache.yml"
  }
  "glpi" = {
    cores     = 2
    memory    = 4096
    disk_size = "20G"
    playbook  = "install_glpi.yml"
  }
  "dc" = {
    cores     = 4
    memory    = 4096
    disk_size = "60G"
    playbook  = "install_ad_ds.yml"
  }
}
```

### `ansible/vars/ad_ds.yml`

Fichier optionnel pour personnaliser Active Directory :

- nom de domaine
- NetBIOS
- OU
- utilisateurs de test
- mots de passe
- redirecteurs DNS

Un exemple est fourni dans [`ansible/vars/ad_ds.yml.example`](/Users/matteoservanty/dev/auto_gsb/ansible/vars/ad_ds.yml.example).

## Configurateur React

Le configurateur web se trouve dans [`web/configurator-react`](/Users/matteoservanty/dev/auto_gsb/web/configurator-react).

Installation et lancement :

```bash
cd web/configurator-react
npm install
npm run dev
```

L'interface permet de :

- construire `.env.local`
- générer `terraform.tfvars`
- générer `ansible/vars/ad_ds.yml`
- produire une commande `bash ./scripts/install_from_generated_config.sh ...` prête à lancer

## Déploiement depuis une configuration générée

Le script [`scripts/install_from_generated_config.sh`](/Users/matteoservanty/dev/auto_gsb/scripts/install_from_generated_config.sh) accepte des contenus encodés en base64 :

```bash
bash ./scripts/install_from_generated_config.sh '<env_local_b64>' '<terraform_tfvars_b64>' '<ad_ds_b64>'
```

Il :

- reconstruit les fichiers de configuration
- les copie à la racine du projet et dans `terraform/`
- exécute `terraform init` si nécessaire
- lance `terraform apply --auto-approve`

## Scripts utiles

- [`install.sh`](/Users/matteoservanty/dev/auto_gsb/install.sh) : bootstrap Proxmox et synchronisation du dépôt
- [`setup.sh`](/Users/matteoservanty/dev/auto_gsb/setup.sh) : assistant de configuration et déploiement principal
- [`deploy_local.sh`](/Users/matteoservanty/dev/auto_gsb/deploy_local.sh) : wrapper de compatibilité vers `setup.sh`
- [`cleanup.sh`](/Users/matteoservanty/dev/auto_gsb/cleanup.sh) : nettoyage local

## Remarques

- le branchement Git par défaut utilisé dans les scripts est `local`
- les secrets sont actuellement stockés en clair dans les fichiers de configuration
- plusieurs playbooks utilisent encore des identifiants ou mots de passe par défaut qui doivent être changés après installation
