# see https://github.com/hashicorp/terraform
terraform {
  required_version = "1.15.8"
  required_providers {
    # see https://registry.terraform.io/providers/dmacvicar/libvirt
    # see https://github.com/dmacvicar/terraform-provider-libvirt
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.8"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

variable "prefix" {
  type    = string
  default = "bootimus-playground-example-vm"
}

variable "vm_count" {
  type    = number
  default = 1
}

variable "network_bridge_device" {
  type    = string
  default = "br-lan"
}

locals {
  cpu_sockets = 1
  cpu_cores   = 4
  cpu_threads = 1
  cpu_total   = local.cpu_sockets * local.cpu_cores * local.cpu_threads
  memory_mib  = 8 * 1024
}

# this uses the vagrant debian image imported from https://github.com/rgl/debian-vagrant.
# see https://registry.terraform.io/providers/dmacvicar/libvirt/0.9.8/docs/resources/volume
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.9.8/docs/resources/volume.md
resource "libvirt_volume" "example_root" {
  count    = var.vm_count
  pool     = "default"
  name     = "${var.prefix}${count.index}-root.img"
  capacity = 64 * 1024 * 1024 * 1024 # GiB.
  target = {
    format = {
      type = "qcow2"
    }
  }
}

# see https://registry.terraform.io/providers/dmacvicar/libvirt/0.9.8/docs/resources/domain
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.9.8/docs/resources/domain.md
resource "libvirt_domain" "example" {
  count       = var.vm_count
  name        = "${var.prefix}${count.index}"
  description = "created from ${path.cwd}"
  running     = true
  type        = "kvm"
  vcpu        = local.cpu_total
  memory      = local.memory_mib
  memory_unit = "MiB"
  # metadata = {
  #   xml = <<-EOF
  #     <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
  #       <libosinfo:os id="http://fedoraproject.org/fedora/44"/>
  #     </libosinfo:libosinfo>
  #     EOF
  # }
  features = {
    acpi = true
    apic = {}
    pae  = true
    smm = {
      state = "on"
    }
    hyper_v = {
      mode = "passthrough"
    }
  }
  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    firmware     = "efi"
    firmware_info = {
      features = [
        {
          name    = "enrolled-keys"
          enabled = "no"
        },
        {
          name    = "secure-boot"
          enabled = "no"
        },
      ]
    }
    sm_bios = {
      mode = "sysinfo"
    }
  }
  cpu = {
    mode = "host-passthrough"
    topology = {
      sockets = local.cpu_sockets
      cores   = local.cpu_cores
      threads = local.cpu_threads
    }
  }
  sys_info = [
    # see ls -laF /sys/firmware/qemu_fw_cfg/by_name/opt/org.tianocore/*/
    # see cat /sys/firmware/qemu_fw_cfg/by_name/opt/org.tianocore/IPv4PXESupport/name
    # see cat /sys/firmware/qemu_fw_cfg/by_name/opt/org.tianocore/IPv4PXESupport/raw
    # see https://github.com/tianocore/edk2/blob/master/OvmfPkg/RUNTIME_CONFIG.md
    # NB for some odd reason, OVMF/EDKII starts PXE immediately on the VM boot,
    #    but it timeouts without sending anything to the network, it seems the
    #    OVMF network stack is not really initialized, thou, after a timeout,
    #    it tries the HTTP Boot, and that works. thou, because of that timeout,
    #    this is kinda slow to start the actual network boot.
    {
      fw_cfg = {
        entry = [
          {
            name  = "opt/org.tianocore/IPv4PXESupport"
            value = "y"
          },
          {
            name  = "opt/org.tianocore/IPv6PXESupport"
            value = "n"
          },
        ]
      }
    },
    {
      # see https://libvirt.org/formatdomain.html#smbios-system-information
      smbios = {
        chassis = {
          entry = [
            {
              name  = "asset"
              value = "example ${count.index}"
            },
          ]
        }
        oem_strings = {
          entry = [
            # see https://systemd.io/CREDENTIALS/
            # see systemd-creds --system list
            # see systemd-creds --system cat foo
            # see cat /run/credentials/@system/foo
            "io.systemd.credential:foo=bar",
          ]
        }
      }
    },
  ]
  devices = {
    graphics = [
      {
        spice = {
          auto_port = true
          listeners = [
            {
              address = {}
            }
          ]
        }
      }
    ]
    videos = [
      {
        model = {
          type    = "qxl"
          primary = "yes"
          vram    = 65536
          ram     = 65536
          vga_mem = 16384
          heads   = 1
        }
      }
    ]
    controllers = [
      {
        type  = "scsi"
        model = "virtio-scsi"
      },
      {
        type = "virtio-serial"
      }
    ]
    channels = [
      {
        source = {
          unix = {
            mode = "bind"
          }
        }
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
      },
    ]
    rngs = [
      {
        model = "virtio"
        backend = {
          random = "/dev/urandom"
        }
      }
    ]
    disks = [
      {
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        source = {
          volume = {
            pool   = libvirt_volume.example_root[count.index].pool
            volume = libvirt_volume.example_root[count.index].name
          }
        }
        target = {
          bus = "scsi"
          dev = "sda"
        }
        wwn = format("000000000000aa%02x", count.index)
        boot = {
          order = 1
        }
      },
    ]
    interfaces = [
      {
        type = "bridge"
        model = {
          type = "virtio"
        }
        mac = {
          # see https://en.wikipedia.org/wiki/MAC_address#Ranges_of_group_and_locally_administered_addresses
          address = format("02:00:00:00:00:%02x", count.index)
        }
        source = {
          bridge = {
            bridge = var.network_bridge_device
          }
        }
        boot = {
          order = 2
        }
      }
    ]
  }
}
