output "containers" {
  description = "Informations de tous les containers créés"
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
  description = "Liste des noms d'hôte des containers"
  value       = { for key, container in proxmox_lxc.container : key => container.hostname }
}

output "container_ids" {
  description = "Liste des IDs des containers"
  value       = { for key, container in proxmox_lxc.container : key => container.id }
}
