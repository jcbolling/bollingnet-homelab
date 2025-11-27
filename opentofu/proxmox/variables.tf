variable "proxmox_api_url" {
  type      = string
  sensitive = true
  default   = null
}

variable "proxmox_api_key_id" {
  type      = string
  sensitive = true
  default   = null
}

variable "proxmox_api_key_secret" {
  type      = string
  sensitive = true
  default   = null
}