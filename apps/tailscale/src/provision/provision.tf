terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.1-rc6"
    }
  }
}

provider "proxmox" {
  pm_api_url      = var.pmApiUrl
  pm_user         = var.pmUsername
  pm_password     = var.pmPassword
  pm_tls_insecure = true
  pm_log_enable   = false
}

variable "pmApiUrl" {
  type = string
  validation {
    condition     = length(var.pmApiUrl) > 0
    error_message = "Proxmox API URL is required."
  }
}

variable "pmUsername" {
  type = string
  validation {
    condition     = length(var.pmUsername) > 0
    error_message = "Proxmox username is required."
  }
}

variable "pmPassword" {
  type = string
  validation {
    condition     = length(var.pmPassword) > 0
    error_message = "Proxmox password is required."
  }
}

variable "hostname" {
  type = string
  validation {
    condition     = length(var.hostname) > 0
    error_message = "Name is required."
  }
}
variable "sshKey" {
  type = string
  validation {
    condition     = length(var.sshKey) > 0
    error_message = "Public SSH key is required."
  }
}

variable "ip" {
  type = string
  validation {
    condition     = length(var.ip) > 0
    error_message = "Ip is required."
  }
}

variable "vmId" {
  type = string
  validation {
    condition     = length(var.vmId) > 0
    error_message = "Ip is required."
  }
}

variable "gateway" {
  type = string
  validation {
    condition     = length(var.gateway) > 0
    error_message = "Gateway is required."
  }
}

variable "nameserver" {
  type = string
  validation {
    condition     = length(var.nameserver) > 0
    error_message = "Nameserver is required."
  }
}

resource "proxmox_lxc" "tailscale" {
  vmid         = var.vmId
  count        = 1
  hostname     = var.hostname
  target_node  = "pve"
  ostemplate   = "nas-iso:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  unprivileged = true
  start        = false
  onboot       = true
  cores        = 2
  memory       = 1024
  swap         = 1024
  startup      = "order=2"

  rootfs {
    storage = "local-lvm"
    size    = "10G"
  }

  ssh_public_keys = <<-EOT
    ${var.sshKey}
  EOT

  nameserver = var.nameserver
  network {
    name     = "eth0"
    bridge   = "vmbr0"
    ip       = var.ip
    ip6      = "auto"
    gw       = var.gateway
    firewall = false
  }
}
