# Script de configuration Active Directory - Après redémarrage
# Ce script s'exécute après que le serveur soit devenu un contrôleur de domaine

$ErrorActionPreference = "Stop"
$LogFile = "C:\Provision\adds-config.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $LogFile -Append
}

# Configuration du domaine
$DomainName = "gsb.local"
$DomainDN = "DC=gsb,DC=local"

Write-Log "===== DEBUT CONFIGURATION POST-INSTALLATION AD ====="

try {
    # Attendre que les services AD soient complètement démarrés
    Write-Log "Attente du démarrage complet des services AD..."
    Start-Sleep -Seconds 60

    # Importer le module Active Directory
    Import-Module ActiveDirectory

    # [1/6] Configurer les redirecteurs DNS
    Write-Log "[1/6] Configuration des redirecteurs DNS..."
    try {
        Add-DnsServerForwarder -IPAddress "8.8.8.8" -PassThru | Out-Null
        Add-DnsServerForwarder -IPAddress "8.8.4.4" -PassThru | Out-Null
        Write-Log "  ✓ Redirecteurs DNS configurés"
    } catch {
        Write-Log "  ⚠ Redirecteurs DNS déjà configurés ou erreur: $_"
    }

    # [2/6] Créer les Unités d'Organisation (OU)
    Write-Log "[2/6] Création des Unités d'Organisation..."

    $OUs = @(
        @{Name="Utilisateurs_GSB"; Description="Utilisateurs de GSB"},
        @{Name="Ordinateurs_GSB"; Description="Ordinateurs de GSB"},
        @{Name="Serveurs_GSB"; Description="Serveurs de GSB"}
    )

    foreach ($ou in $OUs) {
        try {
            $ouPath = "OU=$($ou.Name),$DomainDN"
            if (-not (Get-ADOrganizationalUnit -Filter "distinguishedName -eq '$ouPath'" -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name $ou.Name -Path $DomainDN -Description $ou.Description -ProtectedFromAccidentalDeletion $true
                Write-Log "  ✓ OU créée: $($ou.Name)"
            } else {
                Write-Log "  ⚠ OU existe déjà: $($ou.Name)"
            }
        } catch {
            Write-Log "  ✗ Erreur création OU $($ou.Name): $_"
        }
    }

    # [3/6] Créer un groupe d'administrateurs GSB
    Write-Log "[3/6] Création du groupe Admins_GSB..."
    try {
        $groupPath = "OU=Utilisateurs_GSB,$DomainDN"
        if (-not (Get-ADGroup -Filter "Name -eq 'Admins_GSB'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name "Admins_GSB" `
                -GroupScope Global `
                -GroupCategory Security `
                -Path $groupPath `
                -Description "Administrateurs GSB"
            Write-Log "  ✓ Groupe Admins_GSB créé"
        } else {
            Write-Log "  ⚠ Groupe Admins_GSB existe déjà"
        }
    } catch {
        Write-Log "  ✗ Erreur création groupe: $_"
    }

    # [4/6] Créer un utilisateur administrateur de domaine
    Write-Log "[4/6] Création de l'utilisateur admin.gsb..."
    try {
        $userPath = "OU=Utilisateurs_GSB,$DomainDN"
        if (-not (Get-ADUser -Filter "SamAccountName -eq 'admin.gsb'" -ErrorAction SilentlyContinue)) {
            $password = ConvertTo-SecureString "Admin123@" -AsPlainText -Force
            New-ADUser -Name "admin.gsb" `
                -GivenName "Admin" `
                -Surname "GSB" `
                -SamAccountName "admin.gsb" `
                -UserPrincipalName "admin.gsb@$DomainName" `
                -Path $userPath `
                -AccountPassword $password `
                -Enabled $true `
                -PasswordNeverExpires $true `
                -CannotChangePassword $false

            # Ajouter aux groupes
            Add-ADGroupMember -Identity "Domain Admins" -Members "admin.gsb"
            Add-ADGroupMember -Identity "Admins_GSB" -Members "admin.gsb"

            Write-Log "  ✓ Utilisateur admin.gsb créé et ajouté aux groupes"
        } else {
            Write-Log "  ⚠ Utilisateur admin.gsb existe déjà"
        }
    } catch {
        Write-Log "  ✗ Erreur création utilisateur admin.gsb: $_"
    }

    # [5/6] Créer des utilisateurs de test
    Write-Log "[5/6] Création des utilisateurs de test..."

    $users = @(
        @{Name="user1.gsb"; GivenName="Utilisateur"; Surname="Un"},
        @{Name="user2.gsb"; GivenName="Utilisateur"; Surname="Deux"},
        @{Name="user3.gsb"; GivenName="Utilisateur"; Surname="Trois"}
    )

    foreach ($user in $users) {
        try {
            if (-not (Get-ADUser -Filter "SamAccountName -eq '$($user.Name)'" -ErrorAction SilentlyContinue)) {
                $password = ConvertTo-SecureString "User123@" -AsPlainText -Force
                New-ADUser -Name $user.Name `
                    -GivenName $user.GivenName `
                    -Surname $user.Surname `
                    -SamAccountName $user.Name `
                    -UserPrincipalName "$($user.Name)@$DomainName" `
                    -Path "OU=Utilisateurs_GSB,$DomainDN" `
                    -AccountPassword $password `
                    -Enabled $true `
                    -PasswordNeverExpires $false `
                    -ChangePasswordAtLogon $false
                Write-Log "  ✓ Utilisateur créé: $($user.Name)"
            } else {
                Write-Log "  ⚠ Utilisateur existe déjà: $($user.Name)"
            }
        } catch {
            Write-Log "  ✗ Erreur création utilisateur $($user.Name): $_"
        }
    }

    # [6/6] Marquer la configuration comme terminée
    Write-Log "[6/6] Finalisation..."
    New-Item -Path "C:\Provision\AD_CONFIGURED" -ItemType File -Force | Out-Null
    Write-Log "  ✓ Configuration marquée comme terminée"

    # Supprimer la tâche planifiée
    Unregister-ScheduledTask -TaskName "ConfigureADDS" -Confirm:$false -ErrorAction SilentlyContinue

    Write-Log "===== CONFIGURATION AD TERMINEE AVEC SUCCES ====="

} catch {
    Write-Log "ERREUR: $_"
    Write-Log "ERREUR DETAILS: $($_.Exception.Message)"
    Write-Log "===== CONFIGURATION ECHOUEE ====="
    exit 1
}
