resource "proxmox_lxc" "container" {
  hostname    = var.vm_name
  target_node = var.target_node

  # Template LXC (toujours sur 'local', pas sur LVM)
  ostemplate = var.template_name != "" ? "local:vztmpl/${var.template_name}" : null

  # Ressources
  cores  = var.vm_cores
  memory = var.vm_memory

  # Configuration de base
  ostype       = "debian"
  unprivileged = true
  onboot       = true
  start        = true

  # Disque racine
  rootfs {
    storage = var.vm_storage
    size    = var.vm_disk_size
  }

  # Network
  network {
    name   = "eth0"
    bridge = var.vm_network_bridge
    ip     = "dhcp"
  }

  # Mot de passe root
  password = var.ci_password != "" ? var.ci_password : null

  # Clés SSH (optionnel)
  ssh_public_keys = var.ssh_keys != "" ? var.ssh_keys : null
}
