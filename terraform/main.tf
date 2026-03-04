resource "proxmox_virtual_environment_container" "container" {
  for_each = var.vms

  node_name     = var.target_node
  started       = true
  start_on_boot = true
  unprivileged  = true

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
