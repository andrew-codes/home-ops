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

variable "vmId" {
  type = string
  validation {
    condition     = length(var.vmId) > 0
    error_message = "Proxmox VM ID is required."
  }
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

variable "sshKey" {
  type = string
  validation {
    condition     = length(var.sshKey) > 0
    error_message = "Public SSH key is required."
  }
}

variable "hostname" {
  type = string
  validation {
    condition     = length(var.hostname) > 0
    error_message = "Hostname is required."
  }
}

variable "ip" {
  type = string
  validation {
    condition     = length(var.ip) > 0
    error_message = "Ip is required."
  }
}

variable "nameserver" {
  type = string
  validation {
    condition     = length(var.nameserver) > 0
    error_message = "Nameserver is required."
  }
}

variable "gateway" {
  type = string
  validation {
    condition     = length(var.gateway) > 0
    error_message = "Gateway is required."
  }
}

variable "targetNode" {
  type = string
  validation {
    condition     = length(var.targetNode) > 0
    error_message = "Proxmox target node is required."
  }
}

variable "sourceTemplateId" {
  type = number
}

# GPU passthrough PCI addresses on the Proxmox host (e.g. 0000:01:00.0)
variable "gpuPci" {
  type = string
  validation {
    condition     = length(var.gpuPci) > 0
    error_message = "GPU PCI address is required."
  }
}

variable "gpuAudioPci" {
  type = string
  validation {
    condition     = length(var.gpuAudioPci) > 0
    error_message = "GPU audio PCI address is required."
  }
}

resource "proxmox_vm_qemu" "k8s-main-node" {
  # QoL runtime settings
  define_connection_info = false
  agent_timeout          = 60
  vmid                   = var.vmId
  name                   = var.hostname
  target_node            = var.targetNode

  clone_id   = var.sourceTemplateId
  full_clone = true
  agent      = 1
  onboot     = true

  cpu_type = "host"
  sockets  = 1
  cores    = 16
  memory   = 65536

  scsihw = "virtio-scsi-pci"

  bootdisk = "scsi0"

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Define disks in a single block: primary scsi0 disk + cloud-init drive on ide2
  disks {
    scsi {
      scsi0 {
        disk {
          size    = "320G"
          storage = "local-lvm"
          discard = true
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  # Cloud-Init
  cicustom   = "user=local:snippets/${var.hostname}-user.yaml"
  ipconfig0  = "ip=${var.ip},gw=${var.gateway}"
  nameserver = var.nameserver
  ciuser     = "ubuntu"
  sshkeys    = var.sshKey

  # Machine type for better PCIe support
  machine = "q35"

  # GPU passthrough (graphics + audio)
  pci {
    id     = 0
    raw_id = var.gpuPci
    rombar = false
    pcie   = true
  }
  pci {
    id     = 1
    raw_id = var.gpuAudioPci
    rombar = false
    pcie   = true
  }
}
