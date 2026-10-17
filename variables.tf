variable "region" {
  description = "OCI region. Always Free compute only works in the tenancy's home region."
  type        = string
}

variable "config_file_profile" {
  description = "Profile in ~/.oci/config used for authentication."
  type        = string
  default     = "DEFAULT"
}

variable "compartment_id" {
  description = "Compartment OCID for all resources (the tenancy OCID means the root compartment)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for display names."
  type        = string
  default     = "bgp-lab"
}

variable "ssh_public_key_path" {
  description = "Public key installed on every VM for user ubuntu."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_private_key_path" {
  description = "Private key Terraform uses to push the IPSec/BGP config to the CPE VM."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "my_ip_cidr" {
  description = "CIDR allowed to SSH to the VMs. Leave null to detect your current public IP."
  type        = string
  default     = null
}

variable "a1_ad_index" {
  description = "Availability domain index (0-based) for the Ampere A1 routers. Change it on 'Out of host capacity'."
  type        = number
  default     = 0
}

variable "micro_ad_index" {
  description = "Availability domain index (0-based) for the E2.1.Micro VMs. In multi-AD regions Micro VMs work in one AD only."
  type        = number
  default     = 0
}

variable "hub_cidr" {
  description = "Hub VCN (the 'cloud' side)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "onprem_cidr" {
  description = "On-prem VCN (simulated data centre with the CPE VM)."
  type        = string
  default     = "172.16.0.0/16"
}

variable "onprem_asn" {
  description = "BGP ASN of the CPE VM."
  type        = number
  default     = 65010
}

variable "routers_asn" {
  description = "BGP ASN of the two hub router VMs."
  type        = number
  default     = 65020
}

variable "enable_flow_logs" {
  description = "VCN flow logs on the router subnet (Always Free includes 10 GB/month of logging)."
  type        = bool
  default     = true
}
