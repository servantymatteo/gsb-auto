terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.50.0"
    }
  }
}

locals {
  proxmox_endpoint = trimsuffix(trimsuffix(var.pm_api_url, "/api2/json"), "/")
}

provider "proxmox" {
  endpoint = local.proxmox_endpoint

  # Même format que le repo de référence:
  # api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token}"
  api_token = var.pm_api_token_id != "" && var.pm_api_token_secret != "" ? "${var.pm_api_token_id}=${var.pm_api_token_secret}" : null

  username = var.pm_user != "" ? var.pm_user : null
  password = var.pm_password != "" ? var.pm_password : null

  insecure = var.pm_tls_insecure
}
