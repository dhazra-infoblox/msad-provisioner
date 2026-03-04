# Terraform Variables for vSphere VM Provisioning

variable "vcenter_server" {
  description = "vCenter Server hostname or IP"
  type        = string
}

variable "vcenter_user" {
  description = "vCenter username"
  type        = string
}

variable "vcenter_password" {
  description = "vCenter password"
  type        = string
  sensitive   = true
}

variable "datacenter" {
  description = "vSphere datacenter name"
  type        = string
}

variable "cluster" {
  description = "vSphere cluster name"
  type        = string
}

variable "template" {
  description = "VM template name to clone from"
  type        = string
}

variable "datastore" {
  description = "vSphere datastore name"
  type        = string
}

variable "network" {
  description = "vSphere network name"
  type        = string
}

variable "vm_folder" {
  description = "VM folder name"
  type        = string
  default     = "MSAD-Provisioning"
}

# VM Configuration Map
variable "vms" {
  description = "Map of VMs to provision"
  type = map(object({
    name       = string
    ip_address = string
    subnet_mask = string
    gateway    = string
    dns_servers = list(string)
    cpu        = number
    memory     = number
    disk       = number
  }))
  default = {}
}
