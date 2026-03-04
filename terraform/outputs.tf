output "containers" {
  description = "Informations de tous les containers créés"
  value = {
    for key, container in proxmox_virtual_environment_container.container : key => {
      id       = container.id
      hostname = container.initialization[0].hostname
      vmid     = container.vm_id
      ipv4     = try(container.ipv4["veth0"], null)
      status   = container.started ? "running" : "stopped"
    }
  }
}

output "windows_vms" {
  description = "Informations de toutes les VMs Windows créées"
  value = {
    for key, vm in proxmox_virtual_environment_vm.windows : key => {
      id     = vm.id
      vmid   = vm.vm_id
      name   = vm.name
      ipv4   = try(flatten(vm.ipv4_addresses)[0], null)
      status = vm.started ? "running" : "stopped"
    }
  }
}

output "container_hostnames" {
  description = "Liste des noms d'hôte des containers"
  value       = { for key, container in proxmox_virtual_environment_container.container : key => container.initialization[0].hostname }
}

output "container_ids" {
  description = "Liste des IDs des containers"
  value       = { for key, container in proxmox_virtual_environment_container.container : key => container.id }
}
