# Déploiement automatique de containers Proxmox avec Terraform + Ansible

Système automatisé pour créer et configurer des containers LXC sur Proxmox avec installation automatique de services via Ansible.

## Prérequis

- Terraform installé
- Ansible installé
- Accès à un serveur Proxmox avec API token
- Clés SSH configurées

## Configuration initiale

### 1. Créer le fichier de configuration

Copiez le fichier d'exemple et remplissez-le avec vos informations :

```bash
cp .env.local.example .env.local
nano .env.local
```

### 2. Remplir les informations d'API Proxmox

Le fichier `.env.local` doit contenir :

```bash
# URL de l'API Proxmox
PROXMOX_API_URL=https://192.168.68.200:8006/api2/json

# API Token (voir section ci-dessous pour créer le token)
PROXMOX_TOKEN_ID=root@pam!terraform
PROXMOX_TOKEN_SECRET=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Configuration de base
TARGET_NODE=proxmox
TEMPLATE_NAME=debian-12-standard_12.12-1_amd64.tar.zst
VM_STORAGE=local-lvm

# Credentials par défaut des containers (Cloud-init)
CI_USER=sio2027
CI_PASSWORD=Formation13@
```

### 3. Créer un token API dans Proxmox

1. Connectez-vous à l'interface web Proxmox
2. Datacenter → Permissions → API Tokens
3. Cliquez sur "Add"
4. Sélectionnez l'utilisateur (ex: root@pam)
5. Donnez un nom au token (ex: terraform)
6. **Important** : Copiez le token secret (il ne s'affichera qu'une seule fois !)
7. Collez les valeurs dans votre fichier `.env.local`

## Utilisation rapide

### Méthode 0 : Déploiement one-shot (non interactif)

```bash
./setup.sh
```

Ce script fait tout en une fois :
- création automatique token/ACL Proxmox (si exécuté en root sur Proxmox)
- génération de `.env.local` et `terraform/terraform.tfvars`
- `terraform init` + `terraform apply` (avec retry)
- affichage final des URLs des services

Variables utiles (optionnelles) :
- `VM_PREFIX` (défaut: `GSB`)
- `TARGET_NODE` (défaut: hostname courant)
- `DEPLOY_APACHE=0|1`, `DEPLOY_GLPI=0|1`, `DEPLOY_UPTIME=0|1`
- `DEPLOY_WSERV=0|1` (déploie une VM Windows Server depuis template)
- `PROXMOX_TOKEN_ID` / `PROXMOX_TOKEN_SECRET` (si tu ne veux pas l’auto-création)

### Option : Créer une VM runner Terraform

Depuis un nœud Proxmox (root) :

```bash
./scripts/bootstrap-runner.sh
```

### Méthode 1 : Script interactif (recommandé)

Lancez simplement le script de configuration :

```bash
./setup.sh
```

Le script vous demandera :
1. Le préfixe des containers (ex: SIO2027)
2. Quels services vous voulez installer (Apache, GLPI, etc.)
3. Si vous voulez garder les ressources recommandées (Entrée = oui)
4. Si vous voulez lancer le déploiement immédiatement (Entrée = oui)

Le déploiement via `setup.sh` gère automatiquement :
- la création de `.env.local` (depuis `.env.local.example` si présent)
- la demande uniquement des variables Proxmox vraiment manquantes
- la détection auto de la clé SSH publique (ou génération dans `ssh/`)
- `terraform init`
- jusqu'à 3 tentatives de `terraform apply`

=> Pas besoin de relancer manuellement une 2e commande en cas d'échec transitoire.

### Méthode 2 : Configuration manuelle

Éditez `terraform/terraform.tfvars` et définissez vos VMs :

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
}
```

Puis lancez :

```bash
cd terraform
terraform init
terraform apply --auto-approve
```

## Services disponibles

- **Apache** : Serveur web avec page personnalisée
  - Playbook : `ansible/playbooks/install_apache.yml`
  - Ressources recommandées : 2 CPU, 2048 MB RAM, 10G disque

- **GLPI** : Système de gestion de parc informatique et helpdesk
  - Playbook : `ansible/playbooks/install_glpi.yml`
  - Ressources recommandées : 2 CPU, 4096 MB RAM, 20G disque

- **wSERV (Windows Server)** : VM Windows clonée depuis template Proxmox + provisioning WinRM
  - Playbook : `ansible/playbooks/install_wserv.yml`
  - Ressources recommandées : 4 CPU, 6144 MB RAM, 40G disque
  - Prérequis : template Windows prêt (par défaut VMID `2000`) avec WinRM activé

## Ajouter un nouveau service

1. Créer un playbook Ansible dans `ansible/playbooks/` (ex: `install_monservice.yml`)
2. Ajouter le service dans `setup.sh` :

```bash
SERVICE_NAMES[3]="Mon Service"
SERVICE_PLAYBOOKS[3]="install_monservice.yml"
SERVICE_DEFAULTS[3]="monservice|2|2048|10G"
```

3. Le service sera automatiquement disponible dans le menu

## Structure du projet

```
.
├── README.md                        # Documentation
├── setup.sh                         # Script de configuration et déploiement
├── cleanup.sh                       # Script de suppression des containers
├── terraform/                       # Configuration Terraform
│   ├── main.tf                      # Ressource LXC container
│   ├── variables.tf                 # Définition des variables
│   ├── provider.tf                  # Configuration provider Proxmox
│   ├── outputs.tf                   # Outputs (IPs, hostnames)
│   └── terraform.tfvars             # Valeurs (généré par setup.sh)
├── ansible/                         # Configuration Ansible
│   ├── ansible.cfg                  # Config Ansible (SSH, etc.)
│   └── playbooks/                   # Playbooks d'installation
│       ├── install_apache.yml       # Installation Apache
│       └── install_glpi.yml         # Installation GLPI
├── scripts/                         # Scripts utilitaires
│   └── provision.sh                 # Provisionnement (appelé par Terraform)
└── ssh/                             # Clés SSH
    ├── id_ed25519_terraform         # Clé privée
    └── id_ed25519_terraform.pub     # Clé publique
```

## Comment ça fonctionne

1. **setup.sh** vous pose des questions et génère `terraform/terraform.tfvars`
2. **Terraform** crée les containers LXC sur Proxmox
3. **scripts/provision.sh** récupère les infos du container (VMID, IP)
4. **Ansible** exécute le playbook depuis `ansible/playbooks/`
5. Vous obtenez l'IP d'accès à la fin du déploiement

## Commandes utiles

```bash
# Configurer et déployer de nouvelles VMs (mode interactif)
./setup.sh

# Supprimer UNIQUEMENT les containers créés par ce système
./cleanup.sh

# Voir le plan sans appliquer
cd terraform && terraform plan

# Déployer manuellement
cd terraform && terraform apply --auto-approve

# Voir les outputs (IPs, hostnames)
cd terraform && terraform output
```

## Notes importantes

- Les provisioners Terraform ne s'exécutent que lors de la **création** du container
- Si vous modifiez un playbook, il faut détruire et recréer le container
- Les mots de passe par défaut de GLPI doivent être changés après installation
- Les containers utilisent l'authentification SSH par clé (pas de mot de passe)

## Dépannage

**Erreur "SSH timeout"** :
- Vérifiez que les clés SSH sont présentes dans `ssh/`
- Vérifiez les permissions : `chmod 600 ssh/id_ed25519_terraform`
- Augmentez le délai d'attente dans `scripts/provision.sh`

**Erreur "IP non trouvée"** :
- Vérifiez que le container a bien démarré dans Proxmox
- Vérifiez la configuration réseau (DHCP)

**Ansible échoue** :
- Vérifiez qu'Ansible est installé : `ansible-playbook --version`
- Vérifiez que le playbook existe dans `ansible/playbooks/`
- Vérifiez la config Ansible : `ansible/ansible.cfg`

**Erreur terraform "working directory"** :
- Assurez-vous de lancer terraform depuis le dossier `terraform/`
- Ou utilisez `./setup.sh` qui gère automatiquement les chemins
