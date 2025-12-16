# Configuration Proxmox
variable "pm_api_url" {
  description = "URL de l'API Proxmox"
  type        = string
  default     = "https://proxmox253.m2sformation.com:60002/"
}

variable "pm_api_token_id" {
  description = "Token ID Proxmox (format: user@pam!token-name)"
  type        = string
}

variable "pm_api_token_secret" {
  description = "Secret du token Proxmox"
  type        = string
  sensitive   = true
}

variable "pm_tls_insecure" {
  description = "Ignorer les erreurs de certificat SSL"
  type        = bool
  default     = true
}

# Configuration VM
variable "vm_name" {
  description = "Nom de la VM"
  type        = string
  default     = "vm-terraform"
}

variable "target_node" {
  description = "Nom du nœud Proxmox cible"
  type        = string
}

variable "template_name" {
  description = "Nom du template à cloner"
  type        = string
  default     = ""
}

variable "vm_cores" {
  description = "Nombre de cœurs CPU"
  type        = number
  default     = 2
}

variable "vm_sockets" {
  description = "Nombre de sockets CPU"
  type        = number
  default     = 1
}

variable "vm_memory" {
  description = "Mémoire RAM en MB"
  type        = number
  default     = 2048
}

variable "vm_disk_size" {
  description = "Taille du disque"
  type        = string
  default     = "20G"
}

variable "vm_storage" {
  description = "Storage Proxmox pour le disque"
  type        = string
  default     = "local-lvm"
}

variable "vm_network_bridge" {
  description = "Bridge réseau"
  type        = string
  default     = "vmbr0"
}

variable "ci_user" {
  description = "Utilisateur Cloud-init"
  type        = string
  default     = "ubuntu"
}

variable "ci_password" {
  description = "Mot de passe Cloud-init"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ssh_keys" {
  description = "Clés SSH publiques"
  type        = string
  default     = ""
}
