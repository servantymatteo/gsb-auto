# Proxmox
pm_api_url          = "https://172.25.114.53:8006/api2/json"
pm_api_token_id     = "root@pam!testmatteoryan"
pm_api_token_secret = "91408877-fccc-4be5-8f6e-cfeac61ebdf0"

# VM
vm_name         = "test-vm-SIO2027"
target_node     = "pve"
template_name   = "debian-12-standard_12.12-1_amd64.tar.zst"
vm_cores        = 2
vm_memory       = 4096
vm_disk_size    = "10G"
vm_storage      = "local-lvm"

# Cloud-init
ci_user     = "sio2027"
ci_password = "Formation13@"
# ssh_keys    = ""