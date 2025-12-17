terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.14"
    }
  }
}

provider "proxmox" {
  pm_api_url = var.pm_api_url

  # Authentification par API Token (si défini)
  pm_api_token_id     = var.pm_api_token_id != "" ? var.pm_api_token_id : null
  pm_api_token_secret = var.pm_api_token_secret != "" ? var.pm_api_token_secret : null

  # Authentification par mot de passe (si défini)
  pm_user     = var.pm_user != "" ? var.pm_user : null
  pm_password = var.pm_password != "" ? var.pm_password : null

  pm_tls_insecure = var.pm_tls_insecure
}
