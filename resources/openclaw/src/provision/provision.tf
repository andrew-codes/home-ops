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
  pm_user         = var.pmUser
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

variable "pmUser" {
  type = string
  validation {
    condition     = length(var.pmUser) > 0
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

variable "vmId" {
  type = number
}

variable "ostemplate" {
  type = string
  validation {
    condition     = length(var.ostemplate) > 0
    error_message = "OS template path is required."
  }
}

variable "sshKeys" {
  type = string
  validation {
    condition     = length(var.sshKeys) > 0
    error_message = "Public SSH key(s) are required."
  }
}

variable "ip" {
  type = string
  validation {
    condition     = length(var.ip) > 0
    error_message = "IP CIDR is required."
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

resource "proxmox_lxc" "openclaw" {
  vmid        = var.vmId
  hostname    = "openclaw"
  target_node = "pve"
  ostemplate  = var.ostemplate

  ostype       = "debian"
  unprivileged = false
  start        = true
  onboot       = true

  cores  = 8
  memory = 65536
  swap   = 0

  nameserver = var.nameserver
  startup    = "order=5"

  features {
    nesting = true
  }

  rootfs {
    storage = "local-lvm"
    size    = "320G"
  }

  ssh_public_keys = <<-EOT
    ${var.sshKeys}
  EOT

  network {
    name     = "eth0"
    bridge   = "vmbr0"
    ip       = var.ip
    ip6      = "auto"
    gw       = var.gateway
    firewall = false
  }
}
