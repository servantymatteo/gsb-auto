# Proxmox
pm_api_url          = "https://192.168.68.200:8006/api2/json"
pm_api_token_id     = "root@pam!gsbauto"
pm_api_token_secret = "ffa31e44-bf4a-4586-87b9-d02bdb4640b9"

# VM
vm_name         = "test-vm-SIO2027"
target_node     = "proxmox"
template_name   = "debian-12-standard_12.12-1_amd64.tar.zst"
vm_cores        = 2
vm_memory       = 4096
vm_disk_size    = "10G"
vm_storage      = "local-lvm"

# Cloud-init
ci_user     = "sio2027"
ci_password = "Formation13@"
ssh_keys    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKRUAQH5lQkWRmPhg6zRLzHFH1AGA8AeHVMhcvK9uQzY terraform-gsb"