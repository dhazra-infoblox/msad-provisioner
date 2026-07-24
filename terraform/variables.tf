variable "config_file" {
  description = "Path to YAML configuration file"
  type        = string
  default     = "../config/environment.yml"
}

variable "default_tags" {
  description = "Default tags applied to all AWS resources"
  type        = map(string)
  default = {
    project = "msad-provisioner"
  }
}

variable "admin_password" {
  description = "Domain administrator password (also used for domain join)"
  type        = string
  sensitive   = true
}

variable "safe_mode_password" {
  description = "Active Directory DSRM (safe mode) password"
  type        = string
  sensitive   = true
}

variable "service_password" {
  description = "Service account password for the Infoblox agent user"
  type        = string
  sensitive   = true
}

variable "key_pair_pem_path" {
  description = "Absolute path to the EC2 key pair .pem file used to decrypt Windows Administrator passwords"
  type        = string
  default     = ""
}
