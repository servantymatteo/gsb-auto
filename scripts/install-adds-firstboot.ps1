# Script d'installation automatique d'Active Directory Domain Services
# À exécuter au premier boot de Windows Server

$ErrorActionPreference = "Stop"
$LogFile = "C:\Provision\adds-install.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $LogFile -Append
}

# Configuration du domaine
$DomainName = "gsb.local"
$DomainNetBios = "GSB"
$SafeModePassword = ConvertTo-SecureString "SafeMode123@" -AsPlainText -Force

Write-Log "===== DEBUT INSTALLATION ACTIVE DIRECTORY ====="

try {
    # Vérifier si AD DS est déjà installé
    $addsFeature = Get-WindowsFeature -Name AD-Domain-Services

    if ($addsFeature.InstallState -eq "Installed") {
        Write-Log "AD DS est déjà installé"

        # Vérifier si le serveur est déjà un contrôleur de domaine
        if ((Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole -ge 4) {
            Write-Log "Le serveur est déjà un contrôleur de domaine"
            Write-Log "===== INSTALLATION DEJA COMPLETEE ====="
            exit 0
        }
    } else {
        # [1/3] Installation du rôle AD DS
        Write-Log "[1/3] Installation du rôle AD-Domain-Services..."
        Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        Write-Log "  ✓ Rôle AD-Domain-Services installé"
    }

    # [2/3] Promotion en contrôleur de domaine
    Write-Log "[2/3] Promotion du serveur en contrôleur de domaine..."

    Import-Module ADDSDeployment

    Install-ADDSForest `
        -DomainName $DomainName `
        -DomainNetbiosName $DomainNetBios `
        -SafeModeAdministratorPassword $SafeModePassword `
        -InstallDns:$true `
        -CreateDnsDelegation:$false `
        -DatabasePath "C:\Windows\NTDS" `
        -LogPath "C:\Windows\NTDS" `
        -SysvolPath "C:\Windows\SYSVOL" `
        -NoRebootOnCompletion:$false `
        -Force:$true

    Write-Log "  ✓ Serveur promu en contrôleur de domaine"
    Write-Log "  → Redémarrage en cours..."

} catch {
    Write-Log "ERREUR: $_"
    Write-Log "ERREUR DETAILS: $($_.Exception.Message)"
    Write-Log "===== INSTALLATION ECHOUEE ====="
    exit 1
}
