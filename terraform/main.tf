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

# Create VMs from template
resource "vsphere_virtual_machine" "vm" {
  for_each = var.vms

  name             = each.value.name
  folder           = var.vm_folder
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id

  # Clone from template
  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  # CPU and Memory
  num_cpus  = each.value.cpu
  memory    = each.value.memory
  guest_id  = data.vsphere_virtual_machine.template.guest_id

  # Network
  network_interface {
    adapter_type = "vmxnet3"
    network_id   = data.vsphere_network.network.id
  }

  # Disk
  disk {
    label            = "${each.value.name}-disk0"
    size             = each.value.disk
    thin_provisioned = true
  }

  # Guest Customization for DHCP (initial - Ansible will set static IP)
  # VM will boot with DHCP from vSphere network
  # Static IP configuration is handled by Ansible

  # Wait for guest OS to boot
  wait_for_guest_ip_timeout = 0
}

# Output: Created VMs
output "provisioned_vms" {
  description = "List of provisioned VM names and IPs"
  value = {
    for vm in vsphere_virtual_machine.vm :
    vm.name => {
      ip_address = vm.clone[0].customize[0].ipv4_address
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