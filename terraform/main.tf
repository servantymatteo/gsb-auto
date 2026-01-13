# ========================================
# FILTRES : Séparer les LXC des QEMU VMs
# ========================================
locals {
  # Containers LXC (tous sauf Windows AD DS)
  lxc_vms = {
    for k, v in var.vms : k => v
    if v.playbook != "install_ad_ds.yml"
  }

  # VMs QEMU (Windows uniquement)
  qemu_vms = {
    for k, v in var.vms : k => v
    if v.playbook == "install_ad_ds.yml"
  }

  # URL de base de l'API Proxmox (sans /api2/json)
  api_base_url = trimsuffix(var.pm_api_url, "/api2/json")
}

# ========================================
# CONTAINERS LXC (Linux)
# ========================================
resource "proxmox_lxc" "container" {
  for_each = local.lxc_vms

  hostname    = "${var.vm_name}-${each.key}"
  target_node = var.target_node

  # Template LXC (toujours sur 'local', pas sur LVM)
  ostemplate = var.template_name != "" ? "local:vztmpl/${var.template_name}" : null

  # Ressources (depuis la configuration de chaque VM)
  cores  = each.value.cores
  memory = each.value.memory

  # Configuration de base
  ostype       = "debian"
  unprivileged = true
  onboot       = true
  start        = true

  # Disque racine (depuis la configuration de chaque VM)
  rootfs {
    storage = var.vm_storage
    size    = each.value.disk_size
  }

  # Network
  network {
    name   = "eth0"
    bridge = var.vm_network_bridge
    ip     = "dhcp"
  }

  # Authentification
  password        = var.ci_password
  ssh_public_keys = var.ssh_keys != "" ? var.ssh_keys : null

  # ========================================
  # PROVISIONER ANSIBLE (Linux)
  # ========================================
  provisioner "local-exec" {
    command = "../scripts/provision.sh \"${var.vm_name}-${each.key}\" \"${var.pm_api_url}\" \"${var.pm_api_token_id}\" \"${var.pm_api_token_secret}\" \"${var.target_node}\" \"../ansible/playbooks/${each.value.playbook}\""
  }
}

# ========================================
# VMs QEMU (Windows Server avec Cloud-Init)
# ========================================
# Utilise un template Windows Server avec cloudbase-init préinstallé
# Voir docs/windows-template-setup.md pour créer le template

resource "proxmox_vm_qemu" "windows_vm" {
  for_each = local.qemu_vms

  # Configuration de base
  name        = "${var.vm_name}-${each.key}"
  target_node = var.target_node
  vmid        = 0 # Auto-assign

  # Cloner depuis le template Windows (nom du template)
  clone      = var.windows_template_id
  full_clone = true

  # Configuration matérielle
  cores   = each.value.cores
  sockets = 1
  memory  = each.value.memory
  cpu     = "host"

  # Agent QEMU
  agent = 1

  # Démarrage automatique
  onboot = true

  # BIOS et machine
  bios    = "ovmf"
  machine = "q35"

  # Système d'exploitation
  os_type = "win11"

  # SCSI Controller (virtio-scsi-single pour compatibilité)
  scsihw = "virtio-scsi-single"

  # Boot order
  boot = "order=scsi0"

  # Disk configuration
  disk {
    storage = var.vm_storage
    type    = "scsi"
    size    = each.value.disk_size
    discard = "on"
    iothread = 1
  }

  # Network
  network {
    model  = "virtio"
    bridge = var.vm_network_bridge
  }

  # Configuration Cloud-Init
  ciuser     = "Administrator"
  cipassword = var.windows_admin_password
  ipconfig0  = "ip=dhcp"

  # Scripts Cloud-Init pour AD DS
  # NOTE: Le script doit être uploadé dans /var/lib/vz/snippets/ sur Proxmox
  # Voir terraform/cloud-init/windows-firstboot.ps1
  cicustom = "user=local:snippets/windows-firstboot-adds.yml"

  # Lifecycle
  lifecycle {
    ignore_changes = [
      ciuser,
      network,
    ]
  }

  # ========================================
  # PROVISIONER ANSIBLE (Windows via WinRM)
  # ========================================
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "PROVISIONING WINDOWS: ${var.vm_name}-${each.key}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""

      # Attendre que la VM soit démarrée et cloud-init terminé
      echo "[1/3] Attente du démarrage de la VM et de cloud-init..."
      sleep 60

      # Récupérer l'IP de la VM
      echo "[2/3] Récupération de l'IP de la VM..."

      for i in {1..30}; do
        VM_IP=$(curl -k -s -H "Authorization: PVEAPIToken=${var.pm_api_token_id}=${var.pm_api_token_secret}" \
          "${local.api_base_url}/api2/json/nodes/${var.target_node}/qemu/${self.vmid}/agent/network-get-interfaces" 2>/dev/null | \
          grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v "127.0.0.1" | head -1)

        if [ -n "$VM_IP" ]; then
          echo ""
          echo "   ✓ VM IP trouvée: $VM_IP"
          echo ""
          echo "[3/3] Lancement du provisioning Ansible via WinRM..."
          echo ""

          # Lancer le provisioning PowerShell
          pwsh ../scripts/provision_windows.ps1 \
            -VMName "${var.vm_name}-${each.key}" \
            -VMIP "$VM_IP" \
            -Playbook "../ansible/playbooks/${each.value.playbook}" || true
          break
        fi

        if [ $((i % 5)) -eq 0 ]; then
          echo "   ⏱  Tentative $i/30 - En attente de l'IP..."
        fi
        sleep 10
      done

      if [ -z "$VM_IP" ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠  TIMEOUT: IP non récupérée"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Vérifiez:"
        echo "  1. Le template Windows (ID: ${var.windows_template_id}) existe"
        echo "  2. QEMU Guest Agent est installé et démarré"
        echo "  3. Cloud-init (cloudbase-init) est configuré"
        echo ""
        echo "Puis lancez manuellement:"
        echo "  pwsh scripts/provision_windows.ps1 \\"
        echo "    -VMName ${var.vm_name}-${each.key} \\"
        echo "    -VMIP <IP_DE_LA_VM> \\"
        echo "    -Playbook ansible/playbooks/${each.value.playbook}"
        echo ""
      fi
    EOT
  }
}
