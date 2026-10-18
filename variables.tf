variable "region" {
  description = "OCI region. Null uses the region of the ~/.oci/config profile. Always Free compute only works in the tenancy's home region."
  type        = string
  default     = null
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

variable "micro_ad_index" {
  description = "Availability domain index (0-based) for both VMs. In multi-AD regions E2.1.Micro VMs work in one AD only (see README)."
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
  description = "BGP ASN of the hub router VM."
  type        = number
  default     = 65020
}

variable "enable_flow_logs" {
  description = "VCN flow logs on the router subnet (Always Free includes 10 GB/month of logging)."
  type        = bool
  default     = true
}
