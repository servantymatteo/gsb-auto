output "container_id" {
  description = "ID du container LXC"
  value       = proxmox_lxc.container.id
}

output "container_hostname" {
  description = "Nom d'hôte du container"
  value       = proxmox_lxc.container.hostname
}

output "container_status" {
  description = "Statut du container"
  value       = proxmox_lxc.container.start ? "running" : "stopped"
}
