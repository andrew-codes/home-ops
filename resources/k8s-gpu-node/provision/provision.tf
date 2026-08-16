terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.1-rc6"
    }
  }
}

provider "proxmox" {
  pm_api_url      = var.pm_api_url
  pm_user         = var.pm_user
  pm_password     = var.pm_password
  pm_tls_insecure = true
}

variable "pm_api_url" { type = string }
variable "pm_user" { type = string }
variable "pm_password" { type = string }

variable "vm_id" { type = number }
variable "target_node" { type = string }
variable "source_template_id" { type = number }
variable "storage" { type = string }
variable "bridge" { type = string }
variable "hostname" { type = string }
variable "ip_cidr" { type = string } # e.g. 10.2.0.145/24
variable "gateway" { type = string }
variable "nameserver" { type = string } # space-separated list supported by Proxmox
variable "ssh_public_keys" { type = string }

# VM sizing
variable "cores" { type = number }
variable "memory_mb" { type = number }
variable "disk_gb" { type = number }

# GPU passthrough PCI addresses on Proxmox host (e.g., 01:00.0)
variable "gpu_pci" { type = string }
variable "gpu_audio_pci" { type = string }

resource "proxmox_vm_qemu" "gpu_worker" {
  # QoL runtime settings
  define_connection_info = false
  agent_timeout         = 60
  vmid        = var.vm_id
  name        = var.hostname
  target_node = var.target_node

  clone_id   = var.source_template_id
  full_clone = true
  agent      = 1
  onboot     = true

  cpu_type = "host"
  sockets  = 1
  cores    = var.cores
  memory   = var.memory_mb

  scsihw = "virtio-scsi-pci"


  bootdisk = "scsi0"

  network {
    id     = 0
    model  = "virtio"
    bridge = var.bridge
  }

  # Define disks in a single block: primary scsi0 disk + cloud-init drive on ide2
  disks {
    scsi {
      scsi0 {
        disk {
          size    = "${var.disk_gb}G"
          storage = var.storage
          discard = true
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = var.storage
        }
      }
    }
  }

  # Cloud-Init
  cicustom   = "user=local:snippets/${var.hostname}-user.yaml"
  ipconfig0  = "ip=${var.ip_cidr},gw=${var.gateway}"
  nameserver = var.nameserver
  ciuser    = "ubuntu"
  sshkeys    = var.ssh_public_keys

  # Machine type for better PCIe support
  machine = "q35"

  # GPU passthrough (graphics + audio)
  pci {
    id     = 0
    raw_id = var.gpu_pci
    rombar = false
    pcie   = true
  }
  pci {
    id     = 1
    raw_id = var.gpu_audio_pci
    rombar = false
    pcie   = true
  }
}
