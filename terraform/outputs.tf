# ========================================
# OUTPUTS LXC CONTAINERS
# ========================================
output "containers" {
  description = "Informations de tous les containers LXC créés"
  value = {
    for key, container in proxmox_lxc.container : key => {
      id       = container.id
      hostname = container.hostname
      vmid     = container.vmid
      status   = container.start ? "running" : "stopped"
    }
  }
}

output "container_hostnames" {
  description = "Liste des noms d'hôte des containers LXC"
  value       = { for key, container in proxmox_lxc.container : key => container.hostname }
}

output "container_ids" {
  description = "Liste des IDs des containers LXC"
  value       = { for key, container in proxmox_lxc.container : key => container.id }
}

output "container_ips" {
  description = "Liste des IPs des containers LXC"
  value = {
    for key, container in proxmox_lxc.container : key => try(
      element([for ip in container.network[*].ip : ip if ip != "dhcp"], 0),
      try(
        element(flatten(container.network[*].ipv4_addresses), 0),
        "IP non disponible"
      )
    )
  }
}

# ========================================
# OUTPUTS QEMU VMs (Windows)
# ========================================
output "windows_vms" {
  description = "Informations de toutes les VMs Windows créées"
  value = {
    for key, vm in proxmox_vm_qemu.windows_vm : key => {
      name        = vm.name
      vmid        = vm.vmid
      target_node = vm.target_node
      cores       = vm.cores
      memory      = vm.memory
    }
  }
}

output "windows_vm_names" {
  description = "Liste des noms des VMs Windows créées"
  value = {
    for key, vm in proxmox_vm_qemu.windows_vm : key => vm.name
  }
}

output "windows_vm_ids" {
  description = "Liste des VMIDs des VMs Windows"
  value = {
    for key, vm in proxmox_vm_qemu.windows_vm : key => vm.vmid
  }
}
