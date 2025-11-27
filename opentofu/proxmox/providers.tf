terraform {
  required_providers {
    sops = {
      source = "carlpett/sops"
      version = "~> 0.5"
    }
    proxmox = {
      source = "bpg/proxmox"
      version = "~> 0.87.0"
    }
  }
}

provider "sops" {}

provider "proxmox" {
  endpoint = local.proxmox_api_url
  api_token = "${local.proxmox_api_key_id}=${local.proxmox_api_key_secret}"
  insecure = true
}