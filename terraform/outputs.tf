# Terraform Outputs

output "vms_created" {
  description = "Map of created VMs with their names"
  value       = [for vm in vsphere_virtual_machine.vm : vm.name]
}

output "vm_details" {
  description = "Details of each provisioned VM"
  value = {
    for vm in vsphere_virtual_machine.vm :
    vm.name => {
      id       = vm.id
      uuid     = vm.uuid
      memory   = vm.memory
      num_cpus = vm.num_cpus
    }
  }
}
