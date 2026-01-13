# Guide Complet : Déploiement Windows Server avec Cloud-Init

Ce guide explique comment déployer automatiquement Windows Server avec Active Directory Domain Services en utilisant cloud-init et Terraform.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      PROXMOX SERVER                         │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Template Windows Server 2022                        │  │
│  │  - VMID: 100                                         │  │
│  │  - Cloudbase-Init préinstallé                        │  │
│  │  - QEMU Guest Agent                                  │  │
│  │  - VirtIO Drivers                                    │  │
│  └──────────────────────────────────────────────────────┘  │
│                            │                                │
│                            │ clone                          │
│                            ▼                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  VM Windows AD DS                                    │  │
│  │  - Déployée via Terraform                            │  │
│  │  - Configuration via Cloud-Init                      │  │
│  │  - Installation AD DS automatique                    │  │
│  │  - Provisioning Ansible                              │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Étapes de Déploiement

### Phase 1 : Préparation du Template (Une seule fois)

**Durée : 30-45 minutes**

1. **Créer le template Windows Server 2022**

   Suivez le guide détaillé : [windows-template-setup.md](./windows-template-setup.md)

   Résumé :
   - Installer Windows Server 2022 sur une VM
   - Installer VirtIO Drivers
   - Installer QEMU Guest Agent
   - Installer Cloudbase-Init
   - Sysprep et convertir en template

2. **Vérifier le template**

   ```bash
   ssh root@proxmox-host "qm list | grep 100"
   ```

   Vous devriez voir le template avec VMID 100

### Phase 2 : Configuration des Scripts Cloud-Init

**Durée : 5 minutes**

1. **Uploader le script cloud-init sur Proxmox**

   ```bash
   ./scripts/upload_cloud_init.sh
   ```

   Cela copie le fichier `terraform/cloud-init/windows-firstboot-adds.yml` vers `/var/lib/vz/snippets/` sur Proxmox

2. **Vérifier l'upload**

   ```bash
   ssh root@proxmox-host "ls -lh /var/lib/vz/snippets/windows-firstboot-adds.yml"
   ```

### Phase 3 : Configuration de l'Environnement

**Durée : 2 minutes**

1. **Copier et configurer .env.local**

   ```bash
   cp .env.local.example .env.local
   ```

2. **Éditer .env.local**

   ```bash
   PROXMOX_API_URL=https://192.168.68.200:8006/api2/json
   PROXMOX_TOKEN_ID=root@pam!terraform
   PROXMOX_TOKEN_SECRET=votre-token-secret
   TARGET_NODE=proxmox
   WINDOWS_TEMPLATE_ID=WSERVER-TEMPLATE
   WINDOWS_ADMIN_PASSWORD=Admin123@
   ```

   **⚠️ IMPORTANT**: Utilisez le **nom** de votre template (visible dans l'interface Proxmox), pas l'ID numérique. Par exemple, si votre template s'appelle "WSERVER-TEMPLATE", utilisez ce nom même si son ID est 100.

### Phase 4 : Déploiement avec Terraform

**Durée : 5-10 minutes**

1. **Initialiser Terraform**

   ```bash
   cd terraform
   terraform init
   ```

2. **Configurer les VMs à déployer**

   Créer un fichier `terraform.tfvars` :

   ```hcl
   vms = {
     "ad-dc" = {
       cores     = 2
       memory    = 4096
       disk_size = "50G"
       playbook  = "install_ad_ds.yml"
     }
   }

   vm_name                = "gsb"
   windows_template_id    = "WSERVER-TEMPLATE"
   windows_admin_password = "Admin123@"
   ```

3. **Déployer**

   ```bash
   terraform plan
   terraform apply
   ```

4. **Observer le déploiement**

   - La VM sera clonée depuis le template (30 secondes)
   - Cloud-init configurera Windows (1-2 minutes)
   - Le script firstboot installera AD DS (3-5 minutes)
   - Ansible exécutera la configuration finale (2-3 minutes)

### Phase 5 : Vérification

**Durée : 2 minutes**

1. **Vérifier que la VM est démarrée**

   ```bash
   ssh root@proxmox-host "qm list | grep gsb-ad-dc"
   ```

2. **Vérifier l'IP**

   Dans l'interface Proxmox ou via :

   ```bash
   ssh root@proxmox-host "qm guest cmd <VMID> network-get-interfaces"
   ```

3. **Se connecter à la VM**

   Via la console Proxmox ou RDP :
   - Utilisateur : `Administrator`
   - Mot de passe : `Admin123@`

4. **Vérifier AD DS**

   Dans PowerShell sur la VM Windows :

   ```powershell
   Get-ADDomain
   Get-ADUser -Filter *
   ```

## Workflow de Développement

### Modifier le Script Cloud-Init

1. Éditer `terraform/cloud-init/windows-firstboot-adds.yml`
2. Uploader sur Proxmox :
   ```bash
   ./scripts/upload_cloud_init.sh
   ```
3. Redéployer :
   ```bash
   cd terraform
   terraform destroy -target=proxmox_vm_qemu.windows_vm
   terraform apply
   ```

### Modifier la Configuration Terraform

1. Éditer `terraform/main.tf` ou `terraform/variables.tf`
2. Appliquer les changements :
   ```bash
   cd terraform
   terraform apply
   ```

### Modifier le Playbook Ansible

1. Éditer `ansible/playbooks/install_ad_ds.yml`
2. Relancer uniquement Ansible :
   ```bash
   pwsh scripts/provision_windows.ps1 \
     -VMName gsb-ad-dc \
     -VMIP <IP_DE_LA_VM> \
     -Playbook ansible/playbooks/install_ad_ds.yml
   ```

## Troubleshooting

### La VM ne démarre pas

1. Vérifier que le template existe :
   ```bash
   ssh root@proxmox-host "qm config 100"
   ```

2. Vérifier les logs Terraform :
   ```bash
   terraform apply -auto-approve 2>&1 | tee deploy.log
   ```

### Cloud-Init ne s'exécute pas

1. Vérifier que cloudbase-init est installé dans le template
2. Vérifier les logs dans la VM :
   ```powershell
   Get-Content "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log"
   ```

### AD DS ne s'installe pas

1. Vérifier les logs cloud-init :
   ```powershell
   Get-Content "C:\cloudinit-adds.log"
   ```

2. Vérifier si le rôle est installé :
   ```powershell
   Get-WindowsFeature -Name AD-Domain-Services
   ```

### L'IP n'est pas détectée

1. Vérifier que QEMU Guest Agent est démarré :
   ```powershell
   Get-Service QEMU-GA
   ```

2. Redémarrer le service :
   ```powershell
   Restart-Service QEMU-GA
   ```

### Ansible ne se connecte pas (WinRM)

1. Vérifier que WinRM est activé :
   ```powershell
   Test-WSMan
   ```

2. Vérifier le firewall :
   ```powershell
   Get-NetFirewallRule -Name "WinRM-HTTP"
   ```

3. Activer WinRM manuellement :
   ```powershell
   Enable-PSRemoting -Force
   Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
   ```

## Avantages de cette Architecture

### Par rapport à autounattend.xml :

✅ **Plus rapide** : Pas besoin d'installer Windows à chaque fois
✅ **Plus fiable** : Cloud-init est robuste et testé
✅ **Plus flexible** : Facile de modifier les scripts
✅ **Cohérent** : Même approche que les containers LXC
✅ **Débogage facile** : Logs clairs dans la VM
✅ **Réutilisable** : Un template pour toutes les VMs Windows

### Comparaison des temps :

| Méthode | Temps Total |
|---------|-------------|
| **ISO + autounattend.xml** | 30-40 minutes |
| **Template + Cloud-Init** | 5-10 minutes |

## Scripts Obsolètes

Les scripts suivants ne sont plus nécessaires avec cette architecture :

- ~~`scripts/prepare_windows_iso.sh`~~ → Plus besoin d'ISO personnalisé
- ~~`scripts/create_autounattend_iso.sh`~~ → Plus besoin d'autounattend.xml
- ~~`terraform/autounattend.xml`~~ → Remplacé par cloud-init

## Prochaines Étapes

Une fois AD DS déployé, vous pouvez :

1. **Joindre des machines au domaine**
2. **Créer des GPO (Group Policy Objects)**
3. **Déployer des contrôleurs de domaine secondaires**
4. **Configurer la réplication AD**
5. **Intégrer avec LDAP/Samba**

## Support

Pour toute question ou problème :

1. Consultez les logs dans `C:\cloudinit-adds.log`
2. Vérifiez la documentation : `docs/windows-template-setup.md`
3. Ouvrez une issue GitHub
