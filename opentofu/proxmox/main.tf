data "sops_file" "proxmox_credentials" {
  source_file = "secrets.yaml"
}

locals {
  proxmox_api_url = (
    var.proxmox_api_url != null ?
    var.proxmox_api_url :
    data.sops_file.proxmox_credentials.data["proxmox_api_url"]
  )

  proxmox_api_key_id = (
    var.proxmox_api_key_id != null ?
    var.proxmox_api_key_id :
    data.sops_file.proxmox_credentials.data["proxmox_api_key_id"]
  )

  proxmox_api_key_secret = (
    var.proxmox_api_key_secret != null ?
    var.proxmox_api_key_secret :
    data.sops_file.proxmox_credentials.data["proxmox_api_key_secret"]
  )
}

resource "proxmox_virtual_environment_container" "bn-docker-01" {

  node_name = "bn-prox-01"   # target node
  # vm_id     = 101      # new CT ID (or omit if using random_vm_ids)

  # <-- This is where you reference your template container -->
  clone {
    vm_id     = 100     # your ct-template's VMID
    node_name = "bn-prox-01"  # node where that template/container lives
    # datastore_id = "local-lvm"  # optional: override target storage
  }

  # Now you can override bits from the template as desired
  description   = "Docker host"
  start_on_boot = true
  unprivileged  = true

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
    swap      = 512
  }

  disk {
    datastore_id = "local-lvm"
    size         = 100
  }

  initialization {
    hostname = "bn-docker-01"

    ip_config {
      ipv4 {
        address = "dhcp"
        #address = "192.168.10.50/24"
        #gateway = "192.168.10.1"
      }
    }
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    enabled = true
  }
}
