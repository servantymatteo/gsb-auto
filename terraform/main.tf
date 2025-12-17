resource "proxmox_lxc" "container" {
  for_each = var.vms

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
  # PROVISIONER ANSIBLE
  # ========================================
  # Un "provisioner" = code qui s'exécute APRÈS la création de la ressource
  # Ici, on lance Ansible pour installer Apache après que le container soit créé

  provisioner "local-exec" {
    # "local-exec" = exécute une commande sur votre MACHINE LOCALE (pas dans le container)
    # Autre option : "remote-exec" = exécute dans le container
    # On utilise local-exec car on lance ansible-playbook depuis notre machine

    command = "../scripts/provision.sh \"${var.vm_name}-${each.key}\" \"${var.pm_api_url}\" \"${var.pm_api_token_id}\" \"${var.pm_api_token_secret}\" \"${var.target_node}\" \"../ansible/playbooks/${each.value.playbook}\""

    # Le provisioner ne s'exécute que quand la ressource est CRÉÉE
    # Si vous faites "terraform apply" sur un container déjà existant,
    # le provisioner ne se relance PAS
  }
}
