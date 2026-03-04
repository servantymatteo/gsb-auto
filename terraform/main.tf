resource "proxmox_virtual_environment_container" "container" {
  for_each = var.vms

  node_name     = var.target_node
  started       = true
  start_on_boot = true
  unprivileged  = true
  tags          = [lower(var.vm_name), lower(each.key)]

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
    swap      = 0
  }

  disk {
    datastore_id = var.vm_storage
    size         = tonumber(replace(each.value.disk_size, "G", ""))
  }

  network_interface {
    name   = "veth0"
    bridge = var.vm_network_bridge
  }

  initialization {
    hostname = "${var.vm_name}-${each.key}"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      keys     = var.ssh_keys != "" ? [var.ssh_keys] : []
      password = var.ci_password
    }
  }

  operating_system {
    template_file_id = "local:vztmpl/${var.template_name}"
    type             = "debian"
  }

  features {
    nesting = true
  }

  wait_for_ip {
    ipv4 = true
  }

  provisioner "local-exec" {
    command = "../scripts/provision.sh \"${var.vm_name}-${each.key}\" \"${self.ipv4["veth0"]}\" \"../ansible/playbooks/${each.value.playbook}\""
  }
}

resource "proxmox_virtual_environment_vm" "windows" {
  for_each = var.windows_vms

  name      = "${var.vm_name}-${each.key}"
  node_name = var.target_node
  vm_id     = each.value.vm_id
  tags      = [lower(var.vm_name), lower(each.key)]

  clone {
    vm_id = var.windows_template_vmid
    full  = true
  }

  initialization {
    datastore_id = var.vm_storage

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = var.windows_admin_user
      password = var.windows_admin_password
    }

    user_data_file_id = proxmox_virtual_environment_file.windows_cloudinit[each.key].id
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    interface    = "scsi0"
    datastore_id = var.vm_storage
    size         = tonumber(replace(each.value.disk_size, "G", ""))
  }

  network_device {
    bridge = var.vm_network_bridge
    model  = "virtio"
  }

  agent {
    enabled = true
    timeout = "5m"
  }

  startup {
    order = "2"
  }

  started = true
  on_boot = true
}

resource "proxmox_virtual_environment_file" "windows_cloudinit" {
  for_each = var.windows_vms

  content_type = "snippets"
  datastore_id = var.windows_snippets_datastore
  node_name    = var.target_node

  source_raw {
    file_name = "cloudinit-${var.vm_name}-${each.key}.ps1"
    data = <<-EOT
      #ps1_sysnative
      $ErrorActionPreference = "Stop"

      $DomainName = "${var.windows_domain_name}"
      $Netbios = "${var.windows_domain_netbios}"
      $SafeModePwd = ConvertTo-SecureString "${var.windows_safe_mode_password}" -AsPlainText -Force

      # Active WinRM + firewall pour Ansible/WinRM
      winrm quickconfig -q
      Set-Item -Path WSMan:\\localhost\\Service\\AllowUnencrypted -Value $true
      Set-Item -Path WSMan:\\localhost\\Service\\Auth\\Basic -Value $true
      netsh advfirewall firewall add rule name="WinRM 5985" dir=in action=allow protocol=TCP localport=5985

      # Installe AD DS + DNS puis promeut en DC s'il n'est pas déjà configuré
      Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools

      $adReady = $false
      try {
        Get-ADDomain | Out-Null
        $adReady = $true
      } catch {
        $adReady = $false
      }

      if (-not $adReady) {
        Install-ADDSForest `
          -DomainName $DomainName `
          -DomainNetbiosName $Netbios `
          -InstallDns `
          -SafeModeAdministratorPassword $SafeModePwd `
          -Force `
          -NoRebootOnCompletion:$false
      }
    EOT
  }
}
