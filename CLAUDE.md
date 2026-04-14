# CLAUDE.md — gsb-auto

## Vue d'ensemble

Outil d'automatisation pour déployer une infrastructure GSB sur Proxmox via Terraform + Ansible.
- **Terraform** : crée les containers LXC (Debian) et les VMs Windows sur Proxmox
- **Ansible** : provisionne les services dans chaque container/VM
- **setup.sh** : orchestrateur principal (point d'entrée interactif)
- **install.sh** : bootstrap one-liner (`curl | bash`) qui installe les dépendances puis lance setup.sh

## Architecture

```
install.sh          ← one-liner curl | bash (bootstrap)
setup.sh            ← orchestrateur (interaction utilisateur + terraform + ansible)
scripts/
  provision_windows.sh  ← provisionnement WinRM (Ansible sur Windows)
terraform/          ← ressources Proxmox (LXC + VM Windows)
ansible/
  playbooks/        ← un playbook par service
  vars/             ← variables des playbooks
```

## Services déployables

| ID | Service         | Variable       | Playbook               |
|----|-----------------|----------------|------------------------|
| 1  | Apache          | DEPLOY_APACHE  | install_apache.yml     |
| 2  | GLPI            | DEPLOY_GLPI    | install_glpi.yml       |
| 3  | Uptime Kuma     | DEPLOY_UPTIME  | install_uptime_kuma.yml|
| 4  | Windows Server  | DEPLOY_WSERV   | install_wserv.yml      |
| 5  | Samba AD DC     | DEPLOY_AD      | install_samba_ad.yml   |

## UI / affichage

- Toutes les opérations longues utilisent un **spinner** (`start_spinner` / `stop_spinner`)
- Les commandes bruyantes sont redirigées vers `LOG_FILE=/tmp/gsb-auto-$$.log`
- En cas d'erreur, les dernières lignes du log sont affichées automatiquement
- Ne jamais utiliser `log_info` pour les opérations longues — utiliser `run_step`
- Structure visuelle : `log_title` pour les sections, `log_ok/log_warn/log_err` pour les résultats

## Conventions de code

- Toujours utiliser `run_step "message..." commande args` pour les opérations longues
- Les fonctions qui produisent du bruit (`apt-get`, `terraform`, `ansible-playbook`) doivent rediriger vers `$LOG_FILE`
- `set -euo pipefail` partout — pas de `|| true` sauf pour les opérations vraiment optionnelles
- Les variables d'environnement ont toujours un défaut : `VAR="${VAR:-valeur}"`
- Pas de `echo` brut dans les fonctions — utiliser `log_ok/log_warn/log_err`

## Auth Proxmox

Ordre de préférence :
1. Token API (`PROXMOX_TOKEN_ID` + `PROXMOX_TOKEN_SECRET`) — créé automatiquement si root sur Proxmox
2. Mot de passe (`PROXMOX_PASSWORD`) — fallback, nécessite `pveum` pour les ACLs

## WinRM (Windows Server)

- Transport : `basic` (pas NTLM) — cohérent avec `AllowUnencrypted=true` + `Auth\Basic=true`
- Port : 5985 (HTTP)
- `MaxEnvelopeSizekb` mis à 8192 pour `win_feature` (sinon erreur 400)
- Toujours ajouter `wait_for_connection` après une reconfig WinRM (le service redémarre)

## Structure AD prédéfinie (option 2 du menu)

```
OUs     : Direction, IT, RH, Comptabilite, Commercial
Groupes : GSB-Direction, GSB-IT, GSB-RH, GSB-Comptabilite, GSB-Commercial, GSB-Admins
Users   : dir.general, admin.sys, technicien, responsable.rh, gestionnaire.rh,
          comptable, commercial1, commercial2
```
