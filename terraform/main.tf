# Terraform Configuration for vSphere VM Provisioning

terraform {
  required_version = ">= 1.0"

  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.0"
    }
  }
}

# Provider Configuration
provider "vsphere" {
  vsphere_server       = var.vcenter_server
  user                 = var.vcenter_user
  password             = var.vcenter_password
  allow_unverified_ssl = true
}

# Data: Get vSphere objects
data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "datastore" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.template
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "existing_vm" {
  name          = "test_dc_001"
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Create VMs from template
resource "vsphere_virtual_machine" "vm" {
  for_each = var.vms

  name             = each.value.name
  folder           = var.vm_folder
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id

  # Clone from template with network customization
  clone {
    template_uuid = data.vsphere_virtual_machine.template.id

    customize {
      windows_options {
        computer_name = each.value.name
      }

      network_interface {
        ipv4_address = each.value.ip_address
        ipv4_netmask = 24
      }

      ipv4_gateway    = each.value.gateway
      dns_server_list = each.value.dns_servers
    }
  }

  # CPU and Memory
  num_cpus  = each.value.cpu
  memory    = each.value.memory
  guest_id  = data.vsphere_virtual_machine.template.guest_id
  firmware  = "efi"

  # Storage
  scsi_type = "lsilogic-sas"

  # Network
  network_interface {
    adapter_type          = "e1000e"
    bandwidth_share_count = 50
    network_id            = data.vsphere_network.network.id
  }

  # Disk
  disk {
    label            = "${each.value.name}-disk0"
    size             = each.value.disk
    thin_provisioned = true
  }

  # Wait for guest customization to complete
  wait_for_guest_ip_timeout  = 5
  wait_for_guest_net_timeout = 5
}

# Output: Created VMs
output "provisioned_vms" {
  description = "List of provisioned VMs with their configured static IPs"
  value = {
    for key, vm in vsphere_virtual_machine.vm :
    vm.name => {
      id         = vm.id
      uuid       = vm.uuid
      static_ip  = var.vms[key].ip_address
      gateway    = var.vms[key].gateway
      vsphere_ip = vm.default_ip_address
    }
  }
}

output "template_info" {
  description = "Template details"
  value = {
    id       = data.vsphere_virtual_machine.template.id
    name     = data.vsphere_virtual_machine.template.name
    guest_id = data.vsphere_virtual_machine.template.guest_id
  }
}


output "existing_vm_config" {
  description = "Existing VM configuration details"
  value = {
    guest_id           = data.vsphere_virtual_machine.existing_vm.guest_id
    num_cpus           = data.vsphere_virtual_machine.existing_vm.num_cpus
    memory             = data.vsphere_virtual_machine.existing_vm.memory
    firmware           = data.vsphere_virtual_machine.existing_vm.firmware
    scsi_type          = data.vsphere_virtual_machine.existing_vm.scsi_type
    disks              = data.vsphere_virtual_machine.existing_vm.disks
    network_interfaces = data.vsphere_virtual_machine.existing_vm.network_interfaces
  }
}

output "lan_network_info" {
  description = "LAN Network configuration"
  value = {
    id   = data.vsphere_network.network.id
    name = data.vsphere_network.network.name
    type = data.vsphere_network.network.type
  }
}

output "vm_ips_for_ansible" {
  description = "VM names and configured static IPs for Ansible inventory"
  value = {
    for key, vm in vsphere_virtual_machine.vm :
    vm.name => var.vms[key].ip_address
  }
}
