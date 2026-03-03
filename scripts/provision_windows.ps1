# Script de provisioning pour Windows Server
# Attend que WinRM soit disponible et lance Ansible

param(
    [Parameter(Mandatory=$true)]
    [string]$VMName,

    [Parameter(Mandatory=$true)]
    [string]$VMIP,

    [Parameter(Mandatory=$true)]
    [string]$Playbook
)

$ErrorActionPreference = "Stop"

# Couleurs pour l'affichage
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

Write-ColorOutput "`n╔════════════════════════════════════════╗" "Magenta"
Write-ColorOutput "║   PROVISIONNEMENT WINDOWS + ANSIBLE    ║" "Magenta"
Write-ColorOutput "╚════════════════════════════════════════╝`n" "Magenta"

# [1/4] Attente du démarrage de Windows
Write-ColorOutput "→ [1/4] Démarrage de Windows..." "Cyan"
Start-Sleep -Seconds 120
Write-ColorOutput "   ✓ Windows démarré" "Green"
Write-Host ""

# [2/4] Test de connectivité réseau
Write-ColorOutput "→ [2/4] Test de connectivité réseau..." "Cyan"
$pingSuccess = $false
for ($i = 1; $i -le 30; $i++) {
    if (Test-Connection -ComputerName $VMIP -Count 1 -Quiet) {
        Write-ColorOutput "   ✓ Réseau opérationnel" "Green"
        $pingSuccess = $true
        break
    }
    Start-Sleep -Seconds 5
}

if (-not $pingSuccess) {
    Write-ColorOutput "   ✗ Timeout réseau" "Red"
    exit 1
}
Write-Host ""

# [3/4] Test de connectivité WinRM
Write-ColorOutput "→ [3/4] Test de la connexion WinRM..." "Cyan"
$winrmSuccess = $false
for ($i = 1; $i -le 60; $i++) {
    try {
        $testConnection = Test-WSMan -ComputerName $VMIP -ErrorAction SilentlyContinue
        if ($testConnection) {
            Write-ColorOutput "   ✓ WinRM opérationnel" "Green"
            $winrmSuccess = $true
            break
        }
    } catch {
        # Continuer à attendre
    }
    Start-Sleep -Seconds 5
}

if (-not $winrmSuccess) {
    Write-ColorOutput "   ✗ WinRM timeout" "Red"
    Write-ColorOutput "   ℹ  Vérifiez que WinRM est activé sur la VM Windows" "Yellow"
    exit 1
}
Write-Host ""

# [4/4] Provisionnement via Ansible
Write-ColorOutput "→ [4/4] Provisionnement (Ansible)..." "Cyan"

# Vérifier qu'Ansible est installé
if (-not (Get-Command ansible-playbook -ErrorAction SilentlyContinue)) {
    Write-ColorOutput "   ✗ Ansible non installé" "Red"
    exit 1
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$ansibleConfig = Join-Path $projectRoot "ansible\ansible.cfg"

Write-ColorOutput "   • Cible: $VMIP" "Yellow"
Write-ColorOutput "   • Playbook: $Playbook`n" "Yellow"

# Configuration Ansible pour Windows
$env:ANSIBLE_HOST_KEY_CHECKING = "False"
$env:ANSIBLE_CONFIG = $ansibleConfig

# Créer un inventaire temporaire pour Windows
$inventoryContent = @"
[windows]
$VMIP

[windows:vars]
ansible_user=Administrator
ansible_password=Admin123@
ansible_connection=winrm
ansible_winrm_transport=basic
ansible_winrm_server_cert_validation=ignore
ansible_port=5985
"@

$tempInventory = Join-Path $env:TEMP "inventory_windows.ini"
$inventoryContent | Out-File -FilePath $tempInventory -Encoding ASCII

try {
    # Lancer Ansible
    $ansibleProcess = Start-Process -FilePath "ansible-playbook" `
        -ArgumentList "-i `"$tempInventory`"", "`"$Playbook`"" `
        -NoNewWindow -Wait -PassThru

    if ($ansibleProcess.ExitCode -eq 0) {
        Write-Host ""
        Write-ColorOutput "╔════════════════════════════════════════╗" "Green"
        Write-ColorOutput "║         DÉPLOIEMENT RÉUSSI ! ✓         ║" "Green"
        Write-ColorOutput "╚════════════════════════════════════════╝" "Green"
        Write-Host ""
        Write-ColorOutput "🖥️  VM:        $VMName" "Cyan"
        Write-ColorOutput "🌐 IP:        $VMIP" "Cyan"
        Write-Host ""
    } else {
        Write-Host ""
        Write-ColorOutput "✗ Échec du provisionnement" "Red"
        exit 1
    }
} finally {
    # Nettoyer l'inventaire temporaire
    if (Test-Path $tempInventory) {
        Remove-Item $tempInventory -Force
    }
}
